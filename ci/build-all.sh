#!/bin/bash
# CI driver: build every native input the app links from a clean checkout, then the app,
# then an IPA that a sideloader (SideStore, AltStore, iloader) re-signs.
#
# Follows docs/BUILDING.md. Inputs that are not in the repository come from:
#   llvm-mingw          the pinned release tarball (SHA-256 checked)
#   LLVM for iOS        built here at the recorded commit
#   freetype            the pinned tag, as build/freetype-ios/build.sh documents
#   LuaJIT              a pinned v2.1 commit (GC64 build for LOVE games)
#   x86_64-vcruntime, i386-windows, and the few ignored farm files (dockhost.exe,
#                       dock-notices.txt, aarch64 plugplay/svchost/winedevice)
#                       the upstream release IPA (SHA-256 checked); only files the
#                       checkout lacks are taken from it
#
# Stage cache: each stage has a key, a hash of everything that shapes its output (the
# repository trees and submodule commits it reads, pinned versions, its own shell function,
# and the keys of the stages it builds on), and a list of outputs. When $CACHE holds a
# tarball for that key the outputs are restored instead of built, so a change to app code
# rebuilds only the app. Submodules and Homebrew tools are fetched only by stages that
# actually build. The workflow persists $CACHE between runs.
#
# Each stage logs to $LOGS/<stage>.log. A failed stage is recorded and the script carries on
# with stages that do not depend on it, so one CI run reports as many problems as it can.
# Usage: ci/build-all.sh [stage ...]   (default: all stages, in order)
set -uo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGS="${LOGS:-$R/ci-logs}"
OUT="${OUT:-$R/ci-out}"
CACHE="${CACHE:-$R/.stage-cache}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
mkdir -p "$LOGS" "$OUT" "$CACHE" "$R/toolchains"
rm -f "$CACHE/changed.marker"

MINGW_NAME=llvm-mingw-20260421-ucrt-macos-universal
MINGW_SHA=bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7
MINGW_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/$MINGW_NAME.tar.xz"
LLVM_COMMIT=8dfdcc7b7bf66834a761bd8de445840ef68e4d1a
REL_URL=https://github.com/willfaust/Madeira/releases/download/v0.1.3/Madeira-0.1.3.ipa
REL_SHA=71e900cbc140778bd6fa67c1062821981ed98e6bfb674d853cfeefd6d242e1c0
FREETYPE_TAG=VER-2-13-3
LUAJIT_COMMIT=a4c064539ea931274d407e1249b4bb575424a0f4   # v2.1, 2026-10-21
XCODE_ID="$(xcodebuild -version 2>/dev/null | tr '\n' ' ')$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null)"

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then echo "needs bash >= 4 (run with Homebrew's bash)" >&2; exit 2; fi

# ---------------------------------------------------------------- helpers

# Homebrew formulas a building stage needs; already-installed ones cost nothing.
brew_need() {
    local missing=()
    for f in "$@"; do brew list --formula "$f" >/dev/null 2>&1 || missing+=("$f"); done
    [ ${#missing[@]} -eq 0 ] || HOMEBREW_NO_AUTO_UPDATE=1 brew install "${missing[@]}"
}
# bison 3 and flex for Wine's tools (macOS ships bison 2.3). Homebrew's clang is never put on
# PATH (xcrun's clang builds); the build scripts find Homebrew's llvm-objcopy by path.
wine_tools() { brew_need bison flex pkg-config gettext; export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$PATH"; }

# Submodules a building stage reads; the checkout fetches none.
# A stage restored before (FEX/build-ios, wine/build-macos) may already have put files in the
# submodule's directory, which git will not check out over: move them aside and back.
sub_need() {
    local s tmp
    for s in "$@"; do
        [ -e "$R/$s/.git" ] && continue
        tmp=""
        if [ -d "$R/$s" ] && [ -n "$(ls -A "$R/$s")" ]; then tmp=$(mktemp -d); mv "$R/$s" "$tmp/kept"; fi
        git -C "$R" submodule update --init --depth 1 --recursive --jobs 4 "$s"
        if [ -n "$tmp" ]; then rsync -a "$tmp/kept/" "$R/$s/"; rm -rf "$tmp"; fi
    done
}

declare -A KEY OUTS EXCL SUBS
# key <stage> <input...>: a repository path (its tree, blob or submodule commit), "=text",
# "@stage" (that stage's key) or "%function" (its body).
key() {
    local name=$1; shift
    local parts=("$name" "$XCODE_ID") x
    for x in "$@"; do
        case $x in
            =*) parts+=("${x#=}") ;;
            @*) parts+=("@${x#@}:${KEY[${x#@}]:-none}") ;;
            %*) parts+=("$(declare -f "${x#%}")") ;;
            *)  parts+=("$x:$(git -C "$R" rev-parse "HEAD:$x" 2>/dev/null || echo missing)") ;;
        esac
    done
    KEY[$name]=$(printf '%s\n' "${parts[@]}" | shasum -a 256 | cut -c1-16)
}

restore() {   # restore <stage>: unpack its cached outputs; fails when there are none
    local f="$CACHE/$1-${KEY[$1]}.tar.zst"
    [ -n "${KEY[$1]:-}" ] && [ -f "$f" ] || return 1
    zstd -dcq "$f" | tar -xf - -C "$R"
}

store() {     # store <stage>: pack its outputs under its key, dropping older keys
    local name=$1 f="$CACHE/$1-${KEY[$1]}.tar.zst" paths=() p
    for p in ${OUTS[$name]}; do
        compgen -G "$R/$p" >/dev/null && for x in $R/$p; do paths+=("${x#$R/}"); done
    done
    [ ${#paths[@]} -gt 0 ] || { echo "store $name: no outputs"; return 1; }
    local excl=()
    for p in ${EXCL[$name]:-}; do excl+=(--exclude "$p"); done
    rm -f "$CACHE/$name-"*.tar.zst
    tar -cf - -C "$R" "${excl[@]+"${excl[@]}"}" "${paths[@]}" | zstd -T0 -3 -q -o "$f"
    touch "$CACHE/changed.marker"
    echo "cached $name: $(du -h "$f" | cut -f1)"
}

FAILED=()
declare -A DONE
run() {   # run <stage> <needs...> -- <command...>
    local name=$1; shift
    local needs=()
    while [ "$1" != "--" ]; do needs+=("$1"); shift; done; shift
    for n in "${needs[@]+"${needs[@]}"}"; do
        if [ "${DONE[$n]:-}" != ok ]; then
            echo "::warning::skip $name (needs $n)"; DONE[$name]=skip; FAILED+=("$name(skipped:$n)"); return
        fi
    done
    local t0=$SECONDS
    if [ -n "${OUTS[$name]:-}" ] && restore "$name" 2>"$LOGS/$name.restore.log"; then
        DONE[$name]=ok; echo "ok $name (restored ${KEY[$name]}, $((SECONDS - t0))s)"; return
    fi
    echo "::group::$name"
    if ( set -e; cd "$R"; [ -n "${SUBS[$name]:-}" ] && sub_need ${SUBS[$name]}; "$@" ) > "$LOGS/$name.log" 2>&1; then
        DONE[$name]=ok; echo "ok $name ($((SECONDS - t0))s)"
        [ -n "${OUTS[$name]:-}" ] && store "$name" >> "$LOGS/$name.log" 2>&1
    else
        DONE[$name]=fail; FAILED+=("$name"); echo "::error::$name failed ($((SECONDS - t0))s)"; tail -n 60 "$LOGS/$name.log"
    fi
    echo "::endgroup::"
}

# ---------------------------------------------------------------- stages

st_mingw() {
    curl -sSfL -o "toolchains/$MINGW_NAME.tar.xz" "$MINGW_URL"
    echo "$MINGW_SHA  toolchains/$MINGW_NAME.tar.xz" | shasum -a 256 -c
    tar -xf "toolchains/$MINGW_NAME.tar.xz" -C toolchains
    rm "toolchains/$MINGW_NAME.tar.xz"
}

st_release() {
    local ipa="$R/toolchains/Madeira-0.1.3.ipa" x="$R/toolchains/release-0.1.3"
    if [ ! -d "$x/Payload" ]; then
        curl -sSfL -o "$ipa" "$REL_URL"
        echo "$REL_SHA  $ipa" | shasum -a 256 -c
        mkdir -p "$x"; unzip -q "$ipa" -d "$x"; rm "$ipa"
    fi
    local A="$x/Payload/Madeira.app" M="$R/app/Madeira"
    rsync -a --ignore-existing "$A/x86_64-vcruntime/" "$M/x86_64-vcruntime/"
    rsync -a --ignore-existing "$A/i386-windows/" "$M/i386-windows/"
    for f in arm64ec-windows/dockhost.exe arm64ec-windows/dock-notices.txt \
             aarch64-windows/plugplay.exe aarch64-windows/svchost.exe aarch64-windows/winedevice.exe; do
        [ -e "$M/$f" ] || cp "$A/$f" "$M/$f"
    done
    ls "$M/x86_64-vcruntime" | head; du -sh "$M/i386-windows"
}

st_freetype() {
    brew_need cmake
    [ -d research/freetype ] || git clone -q --depth 1 --branch "$FREETYPE_TAG" https://github.com/freetype/freetype.git research/freetype
    bash build/freetype-ios/build.sh
}

st_gnutls() { brew_need autoconf automake libtool pkg-config; bash build/gnutls-ios/build.sh; }
st_ffmpeg() { brew_need pkg-config; bash build/ffmpeg/build.sh; }
st_fex() {
    brew_need cmake ninja ccache
    # FEX's configure runs Scripts/aarch64_fit_native.py, which imports packaging; without it
    # the script fails and CMake stops at "string sub-command STRIP requires two arguments".
    python3 -c 'import packaging' 2>/dev/null || python3 -m pip install -q --break-system-packages packaging
    bash build/fex-ios/build.sh
}

st_wine_macos() {
    # Host-configured tree whose config.h and generated headers the unix-side builds read.
    # configure insists on a PE cross compiler for aarch64 (no --without-mingw there); only
    # its tools and headers are built here, so the PE side is never compiled.
    wine_tools
    local B=wine/build-macos
    export PATH="$R/toolchains/$MINGW_NAME/bin:$PATH"
    if [ ! -f "$B/Makefile" ]; then
        mkdir -p "$B"
        (cd "$B" && ../configure --without-x --disable-tests --without-freetype \
            --without-gstreamer --without-vulkan --without-opencl --without-cups --without-sane \
            --without-gphoto --without-krb5 --without-netapi --without-pcap --without-usb --without-v4l2)
    fi
    make -C "$B" -j"$JOBS" __tooldeps__
    make -C "$B" -j"$JOBS" include/all || make -C "$B" -j"$JOBS" -k include/all || true
    ls "$B/include/config.h" "$B/tools/winebuild/winebuild"
}

st_wine_pe() {
    # Configures wine/build-arm64ec (its include/ is read by the unix builds) and builds the
    # extra PE modules the farm needs (wintypes: see GAME_MODULES in build-modules.sh).
    wine_tools
    bash build/wine-pe/build-modules.sh wintypes
    ls -la app/Madeira/arm64ec-windows/wintypes.dll
}

st_ntdll()     { wine_tools; bash build/ntdll-unix/build.sh; }
st_wineserver(){ wine_tools; brew_need llvm; bash build/wineserver/build.sh; }
st_win32u()    { wine_tools; bash build/win32u-unix/build.sh; }

st_llvm() {
    brew_need cmake ninja
    local S=toolchains/llvm-project H=toolchains/llvm-host-build I=toolchains/llvm-ios-build
    if [ ! -d "$S/llvm" ]; then
        git init -q "$S"
        git -C "$S" fetch -q --depth 1 https://github.com/llvm/llvm-project.git "$LLVM_COMMIT"
        git -C "$S" checkout -q FETCH_HEAD
    fi
    cmake -G Ninja -S "$S/llvm" -B "$H" -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD= \
        -DLLVM_ENABLE_PROJECTS= -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_LIBXML2=OFF
    ninja -C "$H" llvm-tblgen
    # CMAKE_MACOSX_BUNDLE=OFF: CMake makes every iOS executable an app bundle, and LLVM's
    # install rule for llvm-tblgen then has no BUNDLE DESTINATION (configure error).
    cmake -G Ninja -S "$S/llvm" -B "$I" -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_MACOSX_BUNDLE=OFF \
        -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0 -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 \
        -DLLVM_TARGET_ARCH=host -DLLVM_TARGETS_TO_BUILD= -DLLVM_ENABLE_PROJECTS= -DLLVM_BUILD_TOOLS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_UTILS=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_TABLEGEN="$R/$H/bin/llvm-tblgen" -DLLVM_ENABLE_PIC=OFF
    ninja -C "$I" llvm-libraries
    ls "$I"/lib/libLLVM*.a | wc -l
}

st_dxmt() {
    bash build/dxmt-ios/build.sh
    local B=build/dxmt-ios
    # The script only refreshes libdxmt_combined.a; create it the first time: the unix
    # side plus every LLVM archive (airconv's bitcode reader/writer and their deps).
    xcrun -sdk iphoneos libtool -static -o "$B/libdxmt_combined.a" "$B/libdxmt_unix.a" \
        toolchains/llvm-ios-build/lib/libLLVM*.a
    cp "$B/libdxmt_combined.a" app/Madeira/libdxmt_combined.a
    ls -la app/Madeira/libdxmt_combined.a
}

st_rppairing() {
    rustup target add aarch64-apple-ios
    bash build/rppairing-ios/build.sh
}

st_licenses() { bash build/stage-licenses.sh; }

st_luajit() {
    # A GC64 LuaJIT for LOVE games (Balatro): their own lua51.dll is a non-GC64 build that
    # allocates below 2 GB, which iOS never grants (LuaJITGC64 in Library.swift swaps it in).
    # Shipped as *.dll.madeira so WineProcessBridge's x86_64-vcruntime overlay, which links
    # every *.dll of that folder into system32, leaves it alone.
    local S=toolchains/luajit TC="$R/toolchains/$MINGW_NAME/bin"
    if [ ! -d "$S/src" ]; then
        git init -q "$S"
        git -C "$S" fetch -q --depth 1 https://github.com/LuaJIT/LuaJIT.git "$LUAJIT_COMMIT"
        git -C "$S" checkout -q FETCH_HEAD
    fi
    PATH="$TC:$PATH" make -C "$S/src" -j"$JOBS" HOST_CC="xcrun clang" CROSS=x86_64-w64-mingw32- \
        TARGET_SYS=Windows BUILDMODE=dynamic TARGET_LDFLAGS="-static-libgcc"
    "$TC/llvm-readobj" --coff-imports "$S/src/lua51.dll" | grep -E "Name:" | sort -u
    strings "$S/src/lua51.dll" | grep -m1 "LuaJIT 2.1"
    cp "$S/src/lua51.dll" app/Madeira/x86_64-vcruntime/lua51-gc64.dll.madeira
    ls -la app/Madeira/x86_64-vcruntime/lua51-gc64.dll.madeira
}

st_app() {
    local DD="$R/build/DerivedData"
    xcodebuild -project app/Madeira.xcodeproj -scheme Madeira -configuration Debug \
        -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
        build | tee "$LOGS/xcodebuild-raw.log" | xcbeautify --quiet
    ls -d "$DD/Build/Products/Debug-iphoneos/Madeira.app"
}

st_ipa() {
    local A="$R/build/DerivedData/Build/Products/Debug-iphoneos/Madeira.app" P="$OUT/pkg"
    rm -rf "$P"; mkdir -p "$P/Payload"; cp -R "$A" "$P/Payload/"
    local PA="$P/Payload/Madeira.app"
    # Fakesign with the entitlements so the sideloader carries them over (increased memory
    # limit, JIT, get-task-allow). Nested code first.
    find "$PA" -name "*.dylib" | while read -r x; do ldid -S "$x"; done
    for fw in "$PA"/Frameworks/*.framework; do [ -d "$fw" ] && ldid -S "$fw/$(basename "$fw" .framework)"; done
    for ax in "$PA"/PlugIns/*.appex; do [ -d "$ax" ] && ldid -S"$R/app/Madeira/Madeira.entitlements" "$ax"; done
    ldid -S"$R/app/Madeira/Madeira.entitlements" "$PA"
    ldid -e "$PA/Madeira"
    local V; V=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PA/Info.plist")
    (cd "$P" && zip -qry "$OUT/Madeira-$V-$(git -C "$R" rev-parse --short HEAD).ipa" Payload)
    ls -la "$OUT"/*.ipa
}

# ---------------------------------------------------------------- keys, outputs, submodules

key mingw =$MINGW_SHA %st_mingw
OUTS[mingw]="toolchains/$MINGW_NAME"
key freetype =$FREETYPE_TAG build/freetype-ios %st_freetype
OUTS[freetype]="build/freetype-ios/build/libfreetype.a research/freetype/include"
key gnutls build/gnutls-ios %st_gnutls
OUTS[gnutls]="toolchains/gnutls-ios app/Madeira/libgmp.a app/Madeira/libnettle.a app/Madeira/libhogweed.a app/Madeira/libgnutls.a"
key ffmpeg build/ffmpeg %st_ffmpeg
OUTS[ffmpeg]="toolchains/ffmpeg-ios app/Madeira/libavformat.a app/Madeira/libavcodec.a app/Madeira/libswresample.a app/Madeira/libavutil.a"
key fex FEX build/fex-ios %st_fex
OUTS[fex]="FEX/build-ios"; EXCL[fex]="*.o CMakeFiles"; SUBS[fex]="FEX"
key wine_macos wine @mingw %st_wine_macos
OUTS[wine_macos]="wine/build-macos"; EXCL[wine_macos]="*.o"; SUBS[wine_macos]="wine"
key wine_pe wine build/wine-pe @mingw %st_wine_pe
OUTS[wine_pe]="app/Madeira/arm64ec-windows/wintypes.dll wine/build-arm64ec/include"; SUBS[wine_pe]="wine"
key ntdll wine build/ntdll-unix build/crypto-unix build/hidpad @wine_macos @wine_pe @gnutls @ffmpeg @freetype %st_ntdll
OUTS[ntdll]="app/Madeira/libntdll_unix.a"; SUBS[ntdll]="wine"
key wineserver wine build/wineserver build/ntdll-unix build/hidpad @wine_macos %st_wineserver
OUTS[wineserver]="app/Madeira/libwineserver.a"; SUBS[wineserver]="wine"
key win32u wine build/win32u-unix build/ntdll-unix build/freetype-ios @wine_macos @wine_pe @freetype %st_win32u
OUTS[win32u]="app/Madeira/libwin32u_unix.a"; SUBS[win32u]="wine"
key llvm =$LLVM_COMMIT %st_llvm
OUTS[llvm]="toolchains/llvm-project/llvm/include toolchains/llvm-ios-build/include toolchains/llvm-ios-build/lib/libLLVM*.a"
key dxmt dxmt build/dxmt-ios build/madeira-d3d12 madeira-d3d12 app/Madeira/d3d12 @llvm %st_dxmt
OUTS[dxmt]="app/Madeira/libdxmt_combined.a"; SUBS[dxmt]="dxmt"
key rppairing build/rppairing-ios %st_rppairing
OUTS[rppairing]="app/Madeira/libmadeira_rppairing.a app/Madeira/legal/LICENSES-rppairing-crates.txt"
key luajit =$LUAJIT_COMMIT @mingw %st_luajit
OUTS[luajit]="app/Madeira/x86_64-vcruntime/lua51-gc64.dll.madeira"
SUBS[app]="FEX"

# ---------------------------------------------------------------- run

STAGES=("$@")
[ ${#STAGES[@]} -eq 0 ] && STAGES=(all)
want() { [[ " ${STAGES[*]} " == *" all "* || " ${STAGES[*]} " == *" $1 "* ]]; }

brew_need zstd
want mingw      && run mingw               -- st_mingw
want release    && run release             -- st_release
want freetype   && run freetype            -- st_freetype
want gnutls     && run gnutls              -- st_gnutls
want ffmpeg     && run ffmpeg              -- st_ffmpeg
want fex        && run fex                 -- st_fex
want wine_macos && run wine_macos mingw    -- st_wine_macos
want wine_pe    && run wine_pe mingw       -- st_wine_pe
want ntdll      && run ntdll wine_macos wine_pe gnutls ffmpeg freetype -- st_ntdll
want wineserver && run wineserver wine_macos -- st_wineserver
want win32u     && run win32u wine_macos wine_pe freetype -- st_win32u
want llvm       && run llvm                -- st_llvm
want dxmt       && run dxmt llvm           -- st_dxmt
want rppairing  && run rppairing           -- st_rppairing
want licenses   && run licenses            -- st_licenses
want luajit     && run luajit release mingw -- st_luajit
if want app; then
    needs=(release gnutls ffmpeg fex ntdll wineserver win32u dxmt rppairing licenses luajit)
    [[ " ${STAGES[*]} " == *" all "* ]] || needs=()
    run app "${needs[@]+"${needs[@]}"}" -- st_app
fi
want ipa        && run ipa app             -- st_ipa

echo "== stage results"
for k in "${!DONE[@]}"; do echo "$k: ${DONE[$k]}"; done | sort
if [ ${#FAILED[@]} -gt 0 ]; then echo "::error::failed: ${FAILED[*]}"; exit 1; fi
