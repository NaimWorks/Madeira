#!/bin/bash
# CI driver: build every native input the app links from a clean checkout, then the app,
# then an IPA that a sideloader (SideStore, AltStore, iloader) re-signs.
#
# Follows docs/BUILDING.md. Inputs that are not in the repository come from:
#   llvm-mingw          the pinned release tarball (SHA-256 checked)
#   LLVM for iOS        built here (cached by the workflow) at the recorded commit
#   freetype            the pinned tag, as build/freetype-ios/build.sh documents
#   x86_64-vcruntime, i386-windows, and the few ignored farm files (dockhost.exe,
#                       dock-notices.txt, aarch64 plugplay/svchost/winedevice)
#                       the upstream release IPA (SHA-256 checked); only files the
#                       checkout lacks are taken from it
#
# Each stage logs to $LOGS/<stage>.log. A failed stage is recorded and the script carries on
# with stages that do not depend on it, so one CI run reports as many problems as it can.
# Usage: ci/build-all.sh [stage ...]   (default: all stages, in order)
set -uo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGS="${LOGS:-$R/ci-logs}"
OUT="${OUT:-$R/ci-out}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
mkdir -p "$LOGS" "$OUT" "$R/toolchains"

MINGW_NAME=llvm-mingw-20260421-ucrt-macos-universal
MINGW_SHA=bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7
MINGW_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/$MINGW_NAME.tar.xz"
LLVM_COMMIT=8dfdcc7b7bf66834a761bd8de445840ef68e4d1a
REL_URL=https://github.com/willfaust/Madeira/releases/download/v0.1.3/Madeira-0.1.3.ipa
REL_SHA=71e900cbc140778bd6fa67c1062821981ed98e6bfb674d853cfeefd6d242e1c0
FREETYPE_TAG=VER-2-13-3

# bison 3 and flex for Wine's tools (macOS ships bison 2.3). The build scripts find
# Homebrew's llvm-objcopy by path; Homebrew's clang is never put on PATH (xcrun's clang builds).
export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$PATH"
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then echo "needs bash >= 4 (run with Homebrew's bash)" >&2; exit 2; fi

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
    echo "::group::$name"
    local t0=$SECONDS
    if ( set -e; cd "$R"; "$@" ) > "$LOGS/$name.log" 2>&1; then
        DONE[$name]=ok; echo "ok $name ($((SECONDS - t0))s)"
    else
        DONE[$name]=fail; FAILED+=("$name"); echo "::error::$name failed ($((SECONDS - t0))s)"; tail -n 60 "$LOGS/$name.log"
    fi
    echo "::endgroup::"
}

st_mingw() {
    [ -x "toolchains/$MINGW_NAME/bin/arm64ec-w64-mingw32-clang" ] && return 0
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
    [ -d research/freetype ] || git clone -q --depth 1 --branch "$FREETYPE_TAG" https://github.com/freetype/freetype.git research/freetype
    bash build/freetype-ios/build.sh
}

st_gnutls() { bash build/gnutls-ios/build.sh; }
st_ffmpeg() { bash build/ffmpeg/build.sh; }
st_fex()    { bash build/fex-ios/build.sh; }

st_wine_macos() {
    # Host-configured tree whose config.h and generated headers the unix-side builds read.
    local B=wine/build-macos
    if [ ! -f "$B/Makefile" ]; then
        mkdir -p "$B"
        (cd "$B" && ../configure --without-x --without-mingw --disable-tests --without-freetype \
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
    bash build/wine-pe/build-modules.sh wintypes
    ls -la app/Madeira/arm64ec-windows/wintypes.dll
}

st_ntdll()     { bash build/ntdll-unix/build.sh; }
st_wineserver(){ bash build/wineserver/build.sh; }
st_win32u()    { bash build/win32u-unix/build.sh; }

st_llvm() {
    local S=toolchains/llvm-project H=toolchains/llvm-host-build I=toolchains/llvm-ios-build
    if ls "$I"/lib/libLLVMCore.a >/dev/null 2>&1 && [ -f "$I/include/llvm/Config/llvm-config.h" ]; then
        echo "LLVM for iOS restored from cache"; return 0
    fi
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
    cmake -G Ninja -S "$S/llvm" -B "$I" -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0 -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 \
        -DLLVM_TARGET_ARCH=host -DLLVM_TARGETS_TO_BUILD= -DLLVM_ENABLE_PROJECTS= -DLLVM_BUILD_TOOLS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_UTILS=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_TABLEGEN="$R/$H/bin/llvm-tblgen" -DLLVM_ENABLE_PIC=OFF
    ninja -C "$I" llvm-libraries
    ls "$I"/lib/*.a | wc -l
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

STAGES=("$@")
[ ${#STAGES[@]} -eq 0 ] && STAGES=(all)
want() { [[ " ${STAGES[*]} " == *" all "* || " ${STAGES[*]} " == *" $1 "* ]]; }

want mingw      && run mingw               -- st_mingw
want release    && run release             -- st_release
want freetype   && run freetype            -- st_freetype
want gnutls     && run gnutls              -- st_gnutls
want ffmpeg     && run ffmpeg              -- st_ffmpeg
want fex        && run fex                 -- st_fex
want wine_macos && run wine_macos          -- st_wine_macos
want wine_pe    && run wine_pe mingw       -- st_wine_pe
want ntdll      && run ntdll wine_macos gnutls ffmpeg -- st_ntdll
want wineserver && run wineserver wine_macos -- st_wineserver
want win32u     && run win32u wine_macos freetype -- st_win32u
want llvm       && run llvm                -- st_llvm
want dxmt       && run dxmt llvm           -- st_dxmt
want rppairing  && run rppairing           -- st_rppairing
want licenses   && run licenses            -- st_licenses
if want app; then
    needs=(release gnutls ffmpeg fex ntdll wineserver win32u dxmt rppairing licenses)
    [ " ${STAGES[*]} " == *" all "* ] || needs=()
    run app "${needs[@]+"${needs[@]}"}" -- st_app
fi
want ipa        && run ipa app             -- st_ipa

echo "== stage results"
for k in "${!DONE[@]}"; do echo "$k: ${DONE[$k]}"; done | sort
if [ ${#FAILED[@]} -gt 0 ]; then echo "::error::failed: ${FAILED[*]}"; exit 1; fi
