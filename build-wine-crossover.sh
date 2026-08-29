#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# build-wine-crossover.sh
#
# TruckersMP macOS Compatibility Layer
# GitHub: https://github.com/nohero765/truckersmp-macos
#
# Builds the Wine that CrossOver ships, straight from the CodeWeavers source
# drop, WITH ALL CROSSOVER PATCHES. There is deliberately no patch step: the
# CrossOver source tarball is already the patched tree.
#
# Verified against crossover-sources-26.3.0 and 26.1.0 (both Wine 11.0):
#   260 CrossOver hack sites across 89 files, 76 distinct CW bug IDs.
#   That is a superset of the ~20 patches the old riverfog7/macports build
#   layered onto vanilla WineHQ by hand.
#
# Because the tree ships patched, every source-surgery step the old
# build-wine-devel-2.sh needed is GONE, and re-adding any of it would now
# conflict with the real code:
#   - d3dmetal.c + d3dmetal_objc.m are already in winemac.drv/Makefile.in
#     SOURCES; nothing needs injecting.
#   - macdrv_client_surface_create() is a real function at window.c:1218,
#     declared at macdrv.h:215 — not a wrapper we have to synthesise.
#   - macdrv_functions is already DECLSPEC_EXPORT at d3dmetal.c:397, with a
#     C_ASSERT(sizeof == 192) locking its ABI. That is the symbol DXMT
#     dlsym()s at runtime.
#   - WineMetalLayer, the d3dmetal_client_surface ivar, and the client-surface
#     accessors are all native.
#
# The Metal/DXMT path is x86_64-only: d3dmetal_objc.h is wrapped in
# `#if defined(__x86_64__)`. So this builds x86_64 (+ i386 PE), which runs
# under Rosetta 2 on Apple Silicon. That is how CrossOver itself does it.
#
# Output layout is a plain Wine tree, not an .app bundle:
#   wine/
#     bin/  include/  lib/  share/
#
# Usage: ./build-wine-crossover.sh <crossover-version>
#   e.g. ./build-wine-crossover.sh 26.3.0
#
# Environment:
#   APPLY_STEAM_CEF_HACK=1   apply patches/0001-kernelbase-steamwebhelper-cef.patch
#                            (CW 13322/17315/21883 — the Steam black-login fix
#                            CodeWeavers dropped before CX26). Default 0.
#   WINE_ENABLE_GSTREAMER=0  skip --with-gstreamer even if pkg-config resolves it.
#
# Apart from that one opt-in patch, this script applies nothing of its own.
# What CrossOver ships is what you get.
# ---------------------------------------------------------------------------

# Resolve the directory this script lives in, so patches/ can be found no matter
# where it is invoked from. Not `readlink -f` — macOS's readlink has no -f.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <crossover-version>" >&2
    echo "example: $0 26.3.0" >&2
    exit 2
fi

VERSION="$1"

# Reject anything that isn't a plain dotted version, so the value is safe to
# interpolate into a URL and a filename.
if [[ ! "${VERSION}" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "ERROR: '${VERSION}' is not a valid CrossOver version (expected e.g. 26.3.0)" >&2
    exit 2
fi

WORKSPACE="${WORKSPACE:-$PWD}"

SOURCE_URL="https://media.codeweavers.com/pub/crossover/source/crossover-sources-${VERSION}.tar.gz"
TARBALL="${WORKSPACE}/crossover-sources-${VERSION}.tar.gz"
WORKDIR="${WORKSPACE}/workdir"
BUILDDIR="${WORKDIR}/build-wine"
STAGEDIR="${WORKDIR}/stage"
DESTROOT="${STAGEDIR}/destroot"
WINE_ROOT="${STAGEDIR}/wine"
ARTIFACT="${WORKSPACE}/wine-crossover-${VERSION}-osx64.tar.xz"

group()    { echo "::group::$1"; }
endgroup() { echo "::endgroup::"; }

# ---------------------------------------------------------------------------
group "Download crossover-sources-${VERSION}.tar.gz"
echo "Source URL: ${SOURCE_URL}"
if [[ ! -f "${TARBALL}" ]]; then
    # --retry: the CodeWeavers CDN occasionally drops long transfers.
    curl -fL --retry 3 --retry-delay 5 -o "${TARBALL}" "${SOURCE_URL}"
fi
ls -lh "${TARBALL}"

# A truncated download decompresses partially and then fails much later in a
# confusing place, so verify the gzip stream end-to-end up front.
echo "Verifying archive integrity..."
gzip -t "${TARBALL}" || { echo "ERROR: ${TARBALL} is not a valid gzip stream (truncated download?)"; exit 1; }
echo "  OK"
endgroup

group "Extract sources/wine"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"

# The tarball extracts to a top-level "sources/" directory holding wine plus
# ~15 sibling dependency trees (ghostscript, gstreamer, glib, moltenvk, ...).
# Only sources/wine is needed — the dependencies come from Homebrew — so
# extract just that member. Saves several hundred MB and a lot of I/O.
tar -xzf "${TARBALL}" -C "${WORKDIR}" sources/wine \
    || { echo "ERROR: no 'sources/wine' member in ${TARBALL} — has the tarball layout changed?"; exit 1; }

WINE_SRC="${WORKDIR}/sources/wine"
test -d "${WINE_SRC}" || { echo "ERROR: ${WINE_SRC} not found after extraction"; exit 1; }
test -x "${WINE_SRC}/configure" || { echo "ERROR: ${WINE_SRC}/configure missing or not executable"; exit 1; }
echo "WINE_SRC=${WINE_SRC}"
echo "Wine base: $(cat "${WINE_SRC}/VERSION")"
grep -q "Wine version" "${WINE_SRC}/VERSION" \
    || { echo "ERROR: ${WINE_SRC}/VERSION does not look like a Wine VERSION file"; exit 1; }
endgroup

# ---------------------------------------------------------------------------
group "Confirm CrossOver patches are present in the source tree"
# This build applies NO patches. Instead, assert that the CrossOver hacks are
# already in the tree — that is the whole premise of switching to this source.
# A low count means a truncated extraction or the wrong tarball, and it is much
# better to fail here than after a 40-minute compile.
HACK_SITES=$(grep -rniE "CW[ _-]?HACK|CROSSOVER[ _-]?HACK" \
    "${WINE_SRC}/dlls" "${WINE_SRC}/programs" "${WINE_SRC}/server" \
    "${WINE_SRC}/libs" "${WINE_SRC}/include" "${WINE_SRC}/loader" "${WINE_SRC}/tools" \
    2>/dev/null | wc -l | tr -d ' ' || true)
HACK_IDS=$(grep -rhoiE "(CW|CROSSOVER)[ _-]?HACK[ :]*[0-9]+" \
    "${WINE_SRC}/dlls" "${WINE_SRC}/programs" "${WINE_SRC}/server" \
    "${WINE_SRC}/libs" "${WINE_SRC}/include" "${WINE_SRC}/loader" "${WINE_SRC}/tools" \
    2>/dev/null | grep -oE "[0-9]+" | sort -un | wc -l | tr -d ' ' || true)
echo "CrossOver hack sites: ${HACK_SITES:-0}"
echo "Distinct CW bug IDs:  ${HACK_IDS:-0}"
if [[ "${HACK_SITES:-0}" -lt 100 ]]; then
    echo "ERROR: only ${HACK_SITES} CrossOver hack sites found (expected ~260)."
    echo "       The source tree looks incomplete or is not a CrossOver drop."
    exit 1
fi

echo "--- Named CrossOver hacks that matter to this launcher ---"
# Spot-check specific CW bug IDs rather than trusting the raw count alone.
# All of these were verified present in crossover-sources-26.3.0 and 26.1.0.
# The first column is the CW bug ID; the second is what it is, for the log.
#
# 22435 is the only hard requirement: it is the winemac/D3DMetal work the whole
# DXMT path depends on. The rest are reported so a source drop that quietly
# stopped shipping one of them is visible in the build log.
CRITICAL_ID="22435"
MISSING_IDS=""
for entry in \
    "18947:ntdll" \
    "20186:ntdll" \
    "20760:wow64cpu" \
    "22310:Steam AUMID (winemac cocoa_app)" \
    "22435:winemac D3DMetal — required by DXMT" \
    "23427:ntdll" \
    "24256:ntdll" \
    "24265:ntdll" \
    "24711:ntdll" \
    "24920:CreateProcess" \
    "24938:CreateProcess" \
    "24945:ntdll" \
    "25719:ntdll" \
    "25909:win32u" ; do
    id="${entry%%:*}"; what="${entry#*:}"
    if grep -rqiE "(CW|CROSSOVER)[ _-]?HACK[ :]*${id}" "${WINE_SRC}/dlls" "${WINE_SRC}/programs" 2>/dev/null; then
        echo "  OK      CW ${id} — ${what}"
    else
        echo "  MISSING CW ${id} — ${what}"
        MISSING_IDS="${MISSING_IDS} ${id}"
    fi
done
if [[ -n "${MISSING_IDS}" ]]; then
    echo "  NOTE: not present in this source drop:${MISSING_IDS}"
    for id in ${MISSING_IDS}; do
        if [[ "${id}" == "${CRITICAL_ID}" ]]; then
            echo "ERROR: CW ${CRITICAL_ID} (winemac D3DMetal) is missing — DXMT cannot work against this source."
            exit 1
        fi
    done
fi

echo "--- DXMT / D3DMetal bridge (must all be present, unpatched) ---"
for check in \
    "d3dmetal.c:${WINE_SRC}/dlls/winemac.drv/d3dmetal.c" \
    "d3dmetal_objc.m:${WINE_SRC}/dlls/winemac.drv/d3dmetal_objc.m" ; do
    name="${check%%:*}"; file="${check#*:}"
    test -f "${file}" && echo "  OK   ${name}" \
        || { echo "  FAIL ${name} missing — this source cannot support DXMT"; exit 1; }
done
grep -q "d3dmetal.c"      "${WINE_SRC}/dlls/winemac.drv/Makefile.in" \
    && echo "  OK   d3dmetal.c in winemac.drv/Makefile.in SOURCES" \
    || { echo "  FAIL d3dmetal.c not in Makefile.in SOURCES"; exit 1; }
grep -q "d3dmetal_objc.m" "${WINE_SRC}/dlls/winemac.drv/Makefile.in" \
    && echo "  OK   d3dmetal_objc.m in winemac.drv/Makefile.in SOURCES" \
    || { echo "  FAIL d3dmetal_objc.m not in Makefile.in SOURCES"; exit 1; }
grep -q "DECLSPEC_EXPORT struct macdrv_functions_t macdrv_functions" \
    "${WINE_SRC}/dlls/winemac.drv/d3dmetal.c" \
    && echo "  OK   macdrv_functions exported (the symbol DXMT dlsym()s)" \
    || { echo "  FAIL macdrv_functions not exported from d3dmetal.c"; exit 1; }
grep -qE "^struct macdrv_client_surface \*macdrv_client_surface_create" \
    "${WINE_SRC}/dlls/winemac.drv/window.c" \
    && echo "  OK   macdrv_client_surface_create defined in window.c" \
    || { echo "  FAIL macdrv_client_surface_create not defined in window.c"; exit 1; }
endgroup

group "Patch policy"
# The CrossOver source drop IS the patched tree — all ${HACK_SITES} hack sites
# below come for free and nothing is layered on top of them.
echo "Building CrossOver source as shipped."
echo "All ${HACK_SITES:-0} CrossOver hack sites (${HACK_IDS:-0} distinct CW bug IDs)"
echo "already present in the tree are kept as shipped."
echo

# The one exception: the Steam web-helper CEF hack. CodeWeavers carried it in
# the CX20-era Wine 4/5 tree (CW 13322 / 17315 / 21883) and dropped it before
# CX26's Wine 11.0 — verified absent from 26.3.0 and 26.1.0, no
# hack_append_command_line and no "steamwebhelper" anywhere in dlls/. Without
# it steamwebhelper.exe starts with GPU compositing on, CEF never presents
# through winemac.drv, and Steam's login window paints black with a live,
# clickable DOM. Gated behind APPLY_STEAM_CEF_HACK so a build can be A/B'd
# against a pure-CrossOver one with exactly one variable changed.
STEAM_CEF_PATCH="${STEAM_CEF_PATCH_FILE:-${SCRIPT_DIR}/patches/0001-kernelbase-steamwebhelper-cef.patch}"
if [[ "${APPLY_STEAM_CEF_HACK:-0}" == "1" ]]; then
    echo "Steam CEF hack: REQUESTED"
    test -f "${STEAM_CEF_PATCH}" || {
        echo "  FAIL patch not found at ${STEAM_CEF_PATCH}"
        echo "       The patches/ directory must sit next to this script."
        exit 1
    }
    PROC_C="${WINE_SRC}/dlls/kernelbase/process.c"
    if grep -q "hack_append_command_line" "${PROC_C}"; then
        echo "  OK   already present in the source tree — nothing to do"
    else
        # -F0 is required to actually disable fuzz: patch's DEFAULT max fuzz is 2,
        # so simply omitting -F does NOT give an exact-context apply. A fuzzy
        # apply is how the old build silently dropped hunks, and this patch was
        # generated against this exact tree (all three hunks land at their stated
        # offsets), so anything less than exact means the source moved and the
        # patch needs regenerating rather than forcing.
        #
        # The explicit failure branch matters too: a partial apply exits 1, and
        # under `set -e` that would abort here with no message and skip the
        # content verification below.
        patch -p1 -F0 --forward --no-backup-if-mismatch \
              -d "${WINE_SRC}" < "${STEAM_CEF_PATCH}" \
            || { echo "  FAIL patch did not apply cleanly."
                 echo "       Look for .rej/.orig files under ${WINE_SRC}/dlls/kernelbase/."
                 echo "       The patch is generated against CX26's process.c; if CodeWeavers"
                 echo "       moved that code, regenerate it rather than raising the fuzz."
                 exit 1; }
        echo "  applied"
    fi
    # Verify by content, not by patch's exit code: all three pieces must be
    # there or the hack is a no-op at runtime with no error anywhere.
    for need in \
        'hack_append_command_line' \
        'steamwebhelper\.exe' \
        '--no-sandbox --in-process-gpu --disable-gpu' \
        '--type=crashpad-handler' ; do
        grep -q -- "${need}" "${PROC_C}" \
            && echo "  OK   ${need}" \
            || { echo "  FAIL ${need} missing from process.c after patching"; exit 1; }
    done
    grep -q 'append = hack_append_command_line' "${PROC_C}" \
        && echo "  OK   call site in CreateProcessInternalW" \
        || { echo "  FAIL hack_append_command_line is defined but never called"; exit 1; }
    STEAM_CEF_APPLIED=1
else
    echo "Steam CEF hack: not applied (APPLY_STEAM_CEF_HACK=0)."
    echo "  If Steam's login window is black with clickable buttons, rebuild with"
    echo "  the workflow's steam_cef_hack input set to true."
    STEAM_CEF_APPLIED=0
fi
endgroup

# ---------------------------------------------------------------------------
group "Configure environment"
BREW_PREFIX="$(brew --prefix)"
export CC="ccache clang"
export CXX="ccache clang++"
export i386_CC="ccache i686-w64-mingw32-gcc"
export x86_64_CC="ccache x86_64-w64-mingw32-gcc"
export CPATH="${BREW_PREFIX}/include"
export LIBRARY_PATH="${BREW_PREFIX}/lib"
export MACOSX_DEPLOYMENT_TARGET=10.15
export CFLAGS="-O2 -Wno-deprecated-declarations -Wno-format"
export CROSSCFLAGS="-O2 -Wno-incompatible-pointer-types"
export LDFLAGS="-Wl,-headerpad_max_install_names -Wl,-rpath,@loader_path/../lib -Wl,-rpath,@loader_path/../../ -Wl,-rpath,${BREW_PREFIX}/lib"
export PATH="${BREW_PREFIX}/opt/bison/bin:${PATH}"
# Wine looks for a Vulkan loader by SONAME; on macOS that is MoltenVK.
export ac_cv_lib_soname_vulkan="libMoltenVK.dylib"
echo "BREW_PREFIX=${BREW_PREFIX}"
# `| head -1` can hand the producer a SIGPIPE, which pipefail would turn into a
# build failure. These are informational lines only, so never let them abort.
clang --version 2>&1 | head -1 || true
bison --version 2>&1 | head -1 || true

# --- resolve the SDL2 that will be bundled, and reject sdl2-compat NOW --------
# This has to happen BEFORE configure, not at bundling time. On an Intel runner
# BREW_PREFIX *is* /usr/local, so "prefer /usr/local over Homebrew" is not a real
# distinction: if a linked sdl2-compat owns /usr/local/lib/libSDL2-2.0.0.dylib,
# that is the file that gets picked, and `pkg-config --exists sdl2` cannot tell
# the two apart either. Catching it here costs seconds; catching it at bundling
# time costs configure plus the whole 40-70 minute build first.
SDL2_SRC=""
for candidate in \
  "/usr/local/lib/libSDL2-2.0.0.dylib" \
  "${BREW_PREFIX}/opt/sdl2/lib/libSDL2-2.0.0.dylib" \
  "${BREW_PREFIX}/lib/libSDL2-2.0.0.dylib" \
  "${BREW_PREFIX}/opt/sdl2-compat/lib/libSDL2-2.0.0.dylib" \
  "/usr/local/opt/sdl2-compat/lib/libSDL2-2.0.0.dylib"; do
  if [[ -f "$candidate" ]]; then SDL2_SRC="$candidate"; break; fi
done
if [[ -z "${SDL2_SRC}" ]]; then
  echo "ERROR: no libSDL2-2.0.0.dylib found. Wine would build without a gamepad bus,"
  echo "       and with Disable Hidraw on the bottle would detect no controller at all."
  exit 1
fi
echo "SDL2_SRC=${SDL2_SRC}"
if grep -a 'sdl2-compat' "${SDL2_SRC}" >/dev/null; then
  echo "ERROR: ${SDL2_SRC} is sdl2-compat, not real SDL2."
  echo "       It dlopens libSDL3.dylib at runtime, nothing bundles SDL3, and"
  echo "       SDL_Init() then aborts — killing the SDL gamepad bus. configure"
  echo "       cannot tell the difference, so this is checked here instead of"
  echo "       discovering it after the build."
  echo "       Fix: build real SDL 2.30.12 from source into /usr/local and"
  echo "       'brew unlink sdl2-compat'. Never 'brew install sdl2'."
  exit 1
fi
echo "SDL2: $(grep -a -o -m1 -E 'SDL-release-2\.[0-9]+\.[0-9]+(-[0-9]+-g[0-9a-f]+)?' "${SDL2_SRC}" || echo '<no version string>') ($(stat -f%z "${SDL2_SRC}") bytes)"
endgroup

# ---------------------------------------------------------------------------
group "Configure wine"
mkdir -p "${BUILDDIR}"
pushd "${BUILDDIR}" >/dev/null
# --prefix= (empty) so that `make install DESTDIR=...` lays the tree down as
# bin/ include/ lib/ share/ directly under DESTDIR, which is exactly the
# output layout requested. Wine resolves its own runtime paths relative to the
# loader via dladdr on macOS, so an empty prefix is not a problem at runtime.
#
# NOTE ON OPENGL: the old vanilla-source build passed --without-opengl. It got
# away with that only because its steamwebhelper hack forced --disable-gpu, so
# Steam's CEF rendered in software and never asked for a GL context. This build
# does not force that by default, so GL must work. --with-opengl is deliberately
# NOT passed either: it would make configure hard-fail if detection broke.
# Omitting both lets configure auto-detect and enable it, and the check after
# this step reports what it actually decided.
#
# NOTE ON SDL: --without-sdl is deliberately NOT passed, and the SDL2 that gets
# picked up MUST be real SDL2 — not Homebrew's `sdl2` formula, which is an alias
# for `sdl2-compat` (the SDL2 API reimplemented on top of SDL3).
#
# This is not a style preference; it is a measured failure. CrossOver.app ships
# real SDL 2.30.12 (lib64/libSDL2-2.0.0.dylib, 1366544 bytes, linking
# CoreHaptics + GameController + ForceFeedback). A build that picked up
# sdl2-compat instead shipped a 375408-byte stub that dlopens libSDL3.dylib at
# runtime; with no SDL3 on the user's machine, SDL_Init() aborts (SIGABRT), the
# SDL bus never starts, and because dlls/winebus.sys/main.c:1271 also disables
# the IOHID bus when DisableHidraw=1, the bottle ends up with NO gamepad bus at
# all — no controller, no Bluetooth rumble. The workflow therefore builds SDL
# 2.30.12 from source into /usr/local, and the gate further down hard-fails if
# the bundled dylib turns out to be sdl2-compat.
#
# Wine dlopens SDL2 by soname (configure.ac: WINE_CHECK_SONAME(SDL2, SDL_Init,,,
# [$SDL2_LIBS],[[libSDL2-2.0*]])), so the dylib is bundled into wine/lib below,
# which is on the DYLD_FALLBACK_LIBRARY_PATH the launcher sets. The flag is
# omitted rather than given as --with-sdl for the same hard-fail reason as
# OpenGL; the workflow's pre-flight already gates on `pkg-config --exists sdl2`
# before anything is compiled.
CONFIGURE_ARGS=(
    --prefix=
    --disable-tests
    --enable-winedbg
    --enable-win64
    --enable-archs=i386,x86_64
    --with-coreaudio
    --with-cups
    --with-freetype
    --with-gettext
    --with-gnutls
    --with-mingw
    --with-opencl
    --with-pcap
    --with-pthread
    --with-unwind
    --with-vulkan
    --without-alsa
    --without-capi
    --without-dbus
    --without-fontconfig
    --without-gettextpo
    --without-gphoto
    --without-gssapi
    --without-inotify
    --without-krb5
    --without-netapi
    --without-oss
    --without-pulse
    --without-sane
    --without-udev
    --without-usb
    --without-v4l2
    --without-x
)

# --with-gstreamer only when pkg-config can actually resolve all four modules
# Wine requires (configure.ac: WINE_PACKAGE_FLAGS(GSTREAMER,[gstreamer-1.0
# gstreamer-video-1.0 gstreamer-audio-1.0 gstreamer-tag-1.0])). Passing it
# unconditionally is what turns a missing GStreamer into a hard configure error
# instead of a skipped module, and GStreamer is the one dependency that is not
# reliably installable on an Intel runner any more.
GST_OK=1
for mod in gstreamer-1.0 gstreamer-video-1.0 gstreamer-audio-1.0 gstreamer-tag-1.0; do
    pkg-config --exists "$mod" 2>/dev/null || GST_OK=0
done
if [[ "${WINE_ENABLE_GSTREAMER:-1}" == "1" && "${GST_OK}" == "1" ]]; then
    CONFIGURE_ARGS+=(--with-gstreamer)
    echo "GStreamer: enabled (all four pkg-config modules resolve)"
else
    echo "GStreamer: SKIPPED — not all of gstreamer-1.0/video/audio/tag resolve."
    echo "           Building without winegstreamer; Wine 11's winedmo (FFmpeg)"
    echo "           still provides demuxing. This is not fatal."
fi

"${WINE_SRC}/configure" "${CONFIGURE_ARGS[@]}"
popd >/dev/null
endgroup

group "Post-configure feature check"
CONFIG_H="${BUILDDIR}/include/config.h"
test -f "${CONFIG_H}" || { echo "ERROR: configure did not produce ${CONFIG_H}"; exit 1; }
report_feature() {
    # Match a case-insensitive pattern against the #define lines of config.h
    # rather than hardcoding exact macro names, which differ between Wine
    # versions and would produce misleading warnings if guessed wrong.
    local label="$1" pattern="$2"
    # The alternation MUST be parenthesised: "^#define .*a|b" parses as
    # (^#define .*a) | (b), so the second branch loses the anchor and would match
    # any line at all containing "b".
    if grep -iE "^#define .*(${pattern})" "${CONFIG_H}" >/dev/null 2>&1; then
        echo "  OK    ${label}"
    else
        echo "  WARN  ${label} — no matching #define in config.h"
    fi
}
report_feature "GStreamer" "gstreamer|gst_"
report_feature "FreeType"  "freetype|ft2build"
report_feature "gnutls"    "gnutls"
report_feature "CoreAudio" "coreaudio"
report_feature "OpenGL"    "opengl"
report_feature "Vulkan"    "vulkan"
report_feature "FFmpeg"    "ffmpeg|have_libav"
report_feature "SDL2"      "soname_sdl2|sdl_h"

# SDL2 is dlopened by soname, so the decisive value is SONAME_LIBSDL2 in
# config.h. This is FATAL, not a warning: losing it costs every gamepad and all
# Bluetooth rumble via dlls/winebus.sys/bus_sdl.c, and nothing in the build log
# or at runtime says so — the bottle simply reports no controller. It is the
# exact regression this build shipped once already.
SDL_SONAME=$(grep -iE '^#define SONAME_LIBSDL2' "${CONFIG_H}" 2>/dev/null | head -1 || true)
if [[ -n "${SDL_SONAME}" ]]; then
    echo "  OK    SDL2 soname: ${SDL_SONAME#*SONAME_LIBSDL2 }"
else
    echo "  FAIL  SONAME_LIBSDL2 is not defined in config.h."
    echo "        configure could not find SDL2, so dlls/winebus.sys/bus_sdl.c is a"
    echo "        no-op and the SDL gamepad bus will not exist. With Disable Hidraw"
    echo "        turned on there is then no gamepad bus at all."
    echo "        Fix: install real SDL2 (2.30.x) so that pkg-config --exists sdl2"
    echo "        succeeds and libSDL2-2.0*.dylib is on the linker path."
    exit 1
fi

# winegstreamer is the one the user explicitly asked for, so report its build
# decision from the generated Makefile rather than inferring it from a header.
if grep -qE "^dlls/winegstreamer" "${BUILDDIR}/Makefile" 2>/dev/null; then
    echo "  OK    dlls/winegstreamer is in the build"
else
    echo "  WARN  dlls/winegstreamer is NOT in the build — GStreamer support will be missing"
fi
endgroup

# ---------------------------------------------------------------------------
group "Build wine"
make -C "${BUILDDIR}" -j"$(sysctl -n hw.ncpu)"
endgroup

# ---------------------------------------------------------------------------
group "Install to wine/{bin,include,lib,share}"
rm -rf "${STAGEDIR}"
mkdir -p "${DESTROOT}" "${WINE_ROOT}"

# `make install`, NEVER `make install-image`. CrossOver appends an install-image
# rule (configure.ac, "Crossover hacks" section) that renames bin/wine to
# bin/wineloader and strips the man pages. The launcher looks for wine64/wine by
# name, so a renamed loader would break installation.
make -C "${BUILDDIR}" install DESTDIR="${DESTROOT}"

# With --prefix= empty, DESTROOT now holds bin/ include/ lib/ share/ at its top
# level. Move them under a single "wine" directory, which is the requested shape
# and also what the launcher's archive extraction expects (it does not use
# --strip-components, and findBinary() recurses).
#
# dotglob is scoped to a subshell so this cannot leak the option into the rest of
# the script, and the glob is checked first so an empty DESTROOT reports the real
# cause instead of "mv: rename .../* : No such file or directory".
if [[ -z "$(ls -A "${DESTROOT}" 2>/dev/null)" ]]; then
    echo "ERROR: 'make install' produced nothing under ${DESTROOT}"
    exit 1
fi
( shopt -s dotglob; mv "${DESTROOT}"/* "${WINE_ROOT}/" )
rmdir "${DESTROOT}"

echo "--- wine/ top level ---"
ls -1 "${WINE_ROOT}"
for d in bin include lib share; do
    test -d "${WINE_ROOT}/${d}" && echo "  OK   wine/${d}" \
        || { echo "  FAIL wine/${d} missing"; exit 1; }
done
endgroup

group "Build sanity gates"
test -x "${WINE_ROOT}/bin/wine" || { echo "ERROR: ${WINE_ROOT}/bin/wine missing or not executable"; exit 1; }
file "${WINE_ROOT}/bin/wine"
"${WINE_ROOT}/bin/wine" --version \
    || { echo "ERROR: the freshly built bin/wine failed to run"; exit 1; }
test -x "${WINE_ROOT}/bin/wineserver" || { echo "ERROR: bin/wineserver missing"; exit 1; }

DLL_COUNT=$(find "${WINE_ROOT}/lib/wine/x86_64-windows" -name "*.dll" 2>/dev/null | wc -l | tr -d ' ' || true)
echo "PE DLLs (x86_64-windows): ${DLL_COUNT:-0}"
if [[ "${DLL_COUNT:-0}" -lt 200 ]]; then
    echo "ERROR: build incomplete — only ${DLL_COUNT:-0} PE DLLs (expect 200+)"
    exit 1
fi
DLL_COUNT32=$(find "${WINE_ROOT}/lib/wine/i386-windows" -name "*.dll" 2>/dev/null | wc -l | tr -d ' ' || true)
echo "PE DLLs (i386-windows):   ${DLL_COUNT32:-0}"

# macdrv_functions is what DXMT resolves with dlsym(RTLD_DEFAULT, ...) at
# runtime. If it is not exported the failure is silent — DXMT simply never
# engages — so gate on it here instead of discovering it on real hardware.
# nm on Mach-O prefixes C symbols with an underscore; strip it before matching.
MACDRV_SO="${BUILDDIR}/dlls/winemac.drv/winemac.so"
if [[ -f "${MACDRV_SO}" ]]; then
    # NOTE: plain `grep -w ... >/dev/null`, never `grep -q`, at the end of these
    # pipelines. `grep -q` exits on the first match, which hands nm/awk/sed a
    # SIGPIPE (141); pipefail then reports 141 for the whole pipeline even though
    # grep succeeded, and this gate would fail a perfectly good build. nm output
    # here is well over the 64 KB pipe buffer, so it would bite most runs.
    if nm -g "${MACDRV_SO}" 2>/dev/null | awk '/ [TDSB] /{print $NF}' | sed 's/^_//' | grep -w 'macdrv_functions' >/dev/null; then
        echo "  OK   macdrv_functions exported from winemac.so"
    else
        echo "ERROR: macdrv_functions NOT exported from winemac.so — DXMT's dlsym will fail at runtime"
        exit 1
    fi
    if nm -g "${MACDRV_SO}" 2>/dev/null | awk '/ [TDSB] /{print $NF}' | sed 's/^_//' \
        | grep -w 'macdrv_client_surface_create' >/dev/null; then
        echo "  OK   macdrv_client_surface_create exported"
    else
        echo "  WARN macdrv_client_surface_create not exported (may be internal in this version)"
    fi
else
    echo "  WARN ${MACDRV_SO} not found — skipping symbol gate"
fi

# --- winebus: the gamepad / Bluetooth-rumble path -------------------------
# Three separate things have to be true, and each one fails silently on its own:
#   1. winebus.so must record libSDL2-2.0.0.dylib as its dlopen soname, or
#      bus_sdl.c never runs.
#   2. xbox_bus_init must be present — that is CrossOver's own bus_xbox360.c,
#      which is what presents a controller to the game as an XInput device.
#   3. CW HACK 19629 (rumble over Bluetooth for PS4/PS5 pads) must be in the
#      source that was compiled.
WINEBUS_SO="${WINE_ROOT}/lib/wine/x86_64-unix/winebus.so"
if [[ -f "${WINEBUS_SO}" ]]; then
    if strings -a "${WINEBUS_SO}" | grep -w 'libSDL2-2.0.0.dylib' >/dev/null; then
        echo "  OK   winebus.so records libSDL2-2.0.0.dylib (SDL bus compiled in)"
    else
        echo "ERROR: winebus.so has no libSDL2 soname — the SDL gamepad bus is a no-op."
        echo "       With Disable Hidraw on there would be no gamepad bus at all."
        exit 1
    fi
    # `strings`, not `nm -a`: xbox_bus_init is a static (local) symbol, so it only
    # survives in nm output while the .so is unstripped. Measured against
    # CrossOver's own shipped winemac/winebus, `nm -a | grep -w xbox_bus_init`
    # exits 1 (72 symbols survive there) while `strings -a | grep -w` exits 0.
    # This build is unstripped today, but this gate is a hard exit at the most
    # expensive possible moment, so use the form that works either way.
    if strings -a "${WINEBUS_SO}" | grep -w 'xbox_bus_init' >/dev/null; then
        echo "  OK   xbox_bus_init present (CrossOver's bus_xbox360.c XInput bus)"
    else
        echo "ERROR: xbox_bus_init missing from winebus.so — CrossOver's XInput bus was not built."
        exit 1
    fi
else
    echo "ERROR: ${WINEBUS_SO} not found — winebus.sys did not build"
    exit 1
fi
grep -q "CW HACK 19629" "${WINE_SRC}/dlls/winebus.sys/bus_sdl.c" \
    && echo "  OK   CW HACK 19629 present (PS4/PS5 rumble over Bluetooth)" \
    || echo "  WARN CW HACK 19629 not found in bus_sdl.c — BT rumble may not work"

# --- Steam CEF hack, when it was requested --------------------------------
# The flag strings live in the PE as UTF-16LE, so plain `strings` finds nothing.
# Deleting the NUL bytes turns them back into ASCII, which is enough to grep.
if [[ "${STEAM_CEF_APPLIED:-0}" == "1" ]]; then
    KB_DLL="${WINE_ROOT}/lib/wine/x86_64-windows/kernelbase.dll"
    if [[ -f "${KB_DLL}" ]] \
       && LC_ALL=C tr -d '\000' < "${KB_DLL}" | grep 'steamwebhelper' >/dev/null; then
        echo "  OK   steamwebhelper CEF hack present in the built kernelbase.dll"
    else
        echo "ERROR: the Steam CEF patch was applied to the source but the string is not"
        echo "       in the built kernelbase.dll — the hack would be dead at runtime."
        exit 1
    fi
fi
endgroup

# ---------------------------------------------------------------------------
group "Parity with CrossOver.app"
WINE_UNIX_LIB_CHECK="${WINE_ROOT}/lib/wine/x86_64-unix"
# Inventory taken from a real install:
#   /Applications/CrossOver.app/Contents/SharedSupport/CrossOver
#     lib/wine/x86_64-unix   34 entries (33 .so + the `wine` loader)
#     lib/wine/x86_64-windows 785 PE DLLs
#     lib/wine/i386-windows   845 PE DLLs
# This is a report, not a gate — the differences below are understood and
# documented in the README. It exists so a NEW divergence is visible.
CX_UNIX_MODULES="
  avicap32 bcrypt crypt32 ctapi32 cxcompatdb dnsapi dwrite kerberos localspl
  mountmgr msv1_0 netapi32 nsiproxy ntdll odbc32 opencl opengl32 qcap secur32
  win32u winebth winebus winecoreaudio winedmo winegstreamer winelib winemac
  wineps winevulkan winscard winspool wpcap ws2_32
"
echo "--- lib/wine/x86_64-unix modules vs CrossOver ---"
HAVE=0; LACK=""
for m in ${CX_UNIX_MODULES}; do
  if [[ -f "${WINE_UNIX_LIB_CHECK}/${m}.so" ]]; then
    HAVE=$((HAVE + 1))
  else
    LACK="${LACK} ${m}"
  fi
done
echo "  present: ${HAVE}/33"
if [[ -n "${LACK}" ]]; then
  echo "  absent :${LACK}"
  echo "  reasons:"
  echo "    cxcompatdb, winelib  - CodeWeavers-only, no dlls/ dir in the public source drop"
  echo "    winebth              - no dlls/winebth in this source drop"
  echo "    kerberos             - --without-krb5 in this build's configure flags"
  echo "    netapi32             - --without-netapi"
  echo "    anything else        - unexpected, investigate"
fi
echo "  extra modules we build that CrossOver does not ship:"
for f in "${WINE_UNIX_LIB_CHECK}"/*.so; do
  [[ -f "$f" ]] || continue
  n=$(basename "$f" .so)
  case " ${CX_UNIX_MODULES} " in
    *" ${n} "*) ;;
    *) echo "    ${n}.so" ;;
  esac
done

echo "--- PE DLL counts vs CrossOver ---"
printf "  x86_64-windows: %-6s (CrossOver: 785)\n" "${DLL_COUNT:-0}"
printf "  i386-windows:   %-6s (CrossOver: 845)\n" "${DLL_COUNT32:-0}"

echo "--- media backends ---"
for m in winegstreamer winedmo; do
  [[ -f "${WINE_UNIX_LIB_CHECK}/${m}.so" ]] \
    && echo "  OK   ${m}.so" \
    || echo "  WARN ${m}.so missing — CrossOver ships both (Wine 11 uses winedmo/FFmpeg for demuxing)"
done
endgroup

# ---------------------------------------------------------------------------
group "Bundle external dylibs"
# Homebrew dylibs must travel with the artifact: the user's machine has no
# Homebrew tree at these paths. Copy every /usr/local or /opt/homebrew
# dependency in recursively, then rewrite the load commands to @loader_path.
# This whole section is carried over unchanged in behaviour from the previous
# working build script — only the destination directory differs.
set +o pipefail
WINE_LIB="${WINE_ROOT}/lib"
WINE_UNIX_LIB="${WINE_ROOT}/lib/wine/x86_64-unix"
mkdir -p "${WINE_LIB}" "${WINE_UNIX_LIB}"

# Any load command pointing at one of these prefixes must be copied in and
# rewritten, because none of them exist on a user's machine. The GStreamer entry
# matters because GStreamer comes from the project's official Universal framework
# installed under /Library/Frameworks, not from Homebrew — its dylibs carry
# absolute install names under that path.
GST_FRAMEWORK="/Library/Frameworks/GStreamer.framework/Versions/1.0"
FOREIGN_RE='^(/usr/local/|/opt/homebrew/|/Library/Frameworks/GStreamer\.framework/)'
FOREIGN_GREP='^(/usr/local/|/opt/homebrew/|/Library/Frameworks/GStreamer\.framework/)'

bundle_dep() {
  local src="$1" depname
  depname=$(basename "$src")
  [[ -f "${WINE_LIB}/${depname}" ]] && return 0
  [[ -f "$src" ]] || return 0
  # A bare `cp` here would abort this whole subshell under set -e, and the outer
  # `|| true` on the find pipeline would swallow it — silently skipping the rest
  # of the otool walk and shipping a half-bundled artifact. Fail soft instead.
  cp -Lf "$src" "${WINE_LIB}/" || { echo "  WARN failed to bundle ${depname}"; return 0; }
  # Rewrite the library's own LC_ID_DYLIB too. install_name_tool -change only
  # touches LC_LOAD_DYLIB, so without this every bundled Homebrew dylib keeps a
  # /usr/local or /opt/homebrew install name — which both looks like a leak in
  # the audit below and can make the dynamic loader prefer the absolute path.
  install_name_tool -id "@loader_path/${depname}" "${WINE_LIB}/${depname}" 2>/dev/null || true
  echo "  + ${depname}"
  while IFS= read -r tdep; do
    [[ "$tdep" =~ $FOREIGN_RE ]] || continue
    bundle_dep "$tdep"
  done < <(otool -L "$src" 2>/dev/null | awk 'NR>1{print $1}')
}

echo "=== Recursive otool walk over loader + unix .so modules ==="
find "${WINE_ROOT}/bin" "${WINE_UNIX_LIB}" -type f \
  \( -name "wine" -o -name "wine64" -o -name "wineserver" -o -name "*.so" \) \
| while IFS= read -r f; do
  while IFS= read -r dep; do
    [[ "$dep" =~ $FOREIGN_RE ]] || continue
    bundle_dep "$dep"
  done < <(otool -L "$f" 2>/dev/null | awk 'NR>1{print $1}')
done || true

echo "=== dlopen-only dependencies (not visible to otool) ==="
for candidate in \
  "${BREW_PREFIX}/opt/freetype/lib/libfreetype.6.dylib" \
  "/usr/local/opt/freetype/lib/libfreetype.6.dylib"; do
  [[ -f "$candidate" ]] && { bundle_dep "$candidate"; break; }
done
for candidate in \
  "${BREW_PREFIX}/opt/gnutls/lib/libgnutls.30.dylib" \
  "/usr/local/opt/gnutls/lib/libgnutls.30.dylib"; do
  [[ -f "$candidate" ]] && { bundle_dep "$candidate"; break; }
done
echo "=== SDL2 (dlopened by soname — winebus.sys/bus_sdl.c) ==="
# SDL2_SRC was resolved and validated as real SDL2 back in "Configure
# environment", before configure ran — see the comment there for why the check
# cannot wait until now. This just bundles the file that was already vetted, so
# the gate below inspects the exact bytes that ship.
bundle_dep "${SDL2_SRC}"
echo "  bundled from ${SDL2_SRC}"

# --- reject sdl2-compat -----------------------------------------------------
SDL_BUNDLED="${WINE_LIB}/libSDL2-2.0.0.dylib"
test -f "${SDL_BUNDLED}" || { echo "ERROR: ${SDL_BUNDLED} was not created"; exit 1; }
# grep -a reads the binary directly. Deliberately NOT `strings | grep -m1`:
# grep -m1 exits on the first match, SIGPIPEs strings (141), and pipefail then
# reports the pipeline as failed — the same class of false-failure documented at
# the macdrv_functions gate above.
if grep -a 'sdl2-compat' "${SDL_BUNDLED}" >/dev/null; then
  echo "ERROR: the bundled libSDL2-2.0.0.dylib is sdl2-compat, not real SDL2."
  echo "       sdl2-compat dlopens libSDL3.dylib at runtime; nothing bundles SDL3,"
  echo "       so SDL_Init() aborts and the SDL gamepad bus never starts. With"
  echo "       Disable Hidraw on, the bottle then has no gamepad bus at all."
  echo "       Fix: build real SDL 2.30.12 from source and install it to"
  echo "       /usr/local (see the workflow's 'Build SDL2' step). Do not"
  echo "       'brew install sdl2' — that formula IS sdl2-compat."
  exit 1
fi
# grep -a prints the whole matching LINE, and a Mach-O dylib has no newlines
# anywhere near this string — without -o this captures ~700 bytes of raw binary
# and echoes it into the Actions log. -o prints just the match.
SDL_REL=$(grep -a -o -m1 -E 'SDL-release-2\.[0-9]+\.[0-9]+(-[0-9]+-g[0-9a-f]+)?' "${SDL_BUNDLED}" || true)
if [[ -n "${SDL_REL}" ]]; then
  echo "  OK   real SDL2: ${SDL_REL}  ($(stat -f%z "${SDL_BUNDLED}") bytes)"
  echo "       CrossOver.app ships SDL-release-2.30.12-0-g8236e01a9 (1366544 bytes)"
else
  echo "ERROR: no SDL-release-2.x version string in the bundled dylib — cannot"
  echo "       confirm this is real SDL2. Refusing to ship an unidentified SDL."
  exit 1
fi
# CoreHaptics/GameController/ForceFeedback are what make rumble work at all;
# CrossOver's SDL2 links all three. Report rather than gate, since the exact set
# depends on the SDK the runner has.
echo "  frameworks:"
otool -L "${SDL_BUNDLED}" | grep -oE '(CoreHaptics|GameController|ForceFeedback|CoreAudio)' \
  | sort -u | sed 's/^/    /' || true
if ! otool -L "${SDL_BUNDLED}" | grep 'CoreHaptics' >/dev/null; then
  echo "    WARN CoreHaptics is not linked — Bluetooth rumble may not work"
fi
if otool -L "${SDL_BUNDLED}" | grep -i 'SDL3' >/dev/null; then
  echo "ERROR: the bundled SDL2 links SDL3. That is sdl2-compat in disguise."
  exit 1
fi

echo "=== glib stack + friends (GStreamer's runtime deps) ==="
# CrossOver.app's lib64/ carries all of these next to the gst libs. The
# otool-recursive walk normally finds them through winegstreamer.so, but list
# them explicitly so a change in what links what cannot quietly drop one.
for lib in \
  libglib-2.0.0 libgobject-2.0.0 libgio-2.0.0 libgmodule-2.0.0 libgthread-2.0.0 \
  libffi.8 libintl.8 libpcre2-8.0 libgmp.10 libnettle.8 libhogweed.6 libtasn1.6 \
  libidn2.0 libunistring.5 libp11-kit.0 liborc-0.4.0 ; do
  for candidate in \
    "${BREW_PREFIX}/lib/${lib}.dylib" \
    "/usr/local/lib/${lib}.dylib"; do
    [[ -f "$candidate" ]] && { bundle_dep "$candidate"; break; }
  done
done

echo "=== MoltenVK ==="
MOLTEN_FOUND=""
for candidate in \
  "${BREW_PREFIX}/opt/molten-vk/lib/libMoltenVK.dylib" \
  "${BREW_PREFIX}/lib/libMoltenVK.dylib" \
  "/usr/local/opt/molten-vk/lib/libMoltenVK.dylib" \
  "/usr/local/lib/libMoltenVK.dylib"; do
  if [[ -f "$candidate" ]]; then
    cp -Lf "$candidate" "${WINE_LIB}/" || { echo "  WARN failed to copy libMoltenVK.dylib"; break; }
    install_name_tool -id "@loader_path/libMoltenVK.dylib" "${WINE_LIB}/libMoltenVK.dylib" 2>/dev/null || true
    echo "  + libMoltenVK.dylib"
    MOLTEN_FOUND=1; break
  fi
done
[[ -n "$MOLTEN_FOUND" ]] || echo "  WARN libMoltenVK.dylib not found — Vulkan/Metal bridge absent"

echo "=== GStreamer plugins ==="
# CrossOver.app ships a CURATED set of 17 plugins in lib64/gstreamer-1.0/, not
# Homebrew's full ~120. Copying only these matches CrossOver exactly, keeps the
# artifact small, and avoids dragging in plugins whose own dependency chains
# (gtk4, librsvg, python) would then need bundling too.
#
# Inventory taken from CrossOver.app/Contents/SharedSupport/CrossOver/lib64/gstreamer-1.0/
CX_GST_PLUGINS="
  libgstapplemedia libgstasf libgstaudioconvert libgstaudioparsers
  libgstaudioresample libgstavi libgstcoreelements libgstdeinterlace
  libgstid3demux libgstisomp4 libgstopengl libgstplayback
  libgsttypefindfunctions libgstvideoconvertscale libgstvideofilter
  libgstvideoparsersbad libgstwavparse
"
mkdir -p "${WINE_LIB}/gstreamer-1.0"
GST_SRC_DIR=""
for gst_dir in \
  "${GST_FRAMEWORK}/lib/gstreamer-1.0" \
  "${BREW_PREFIX}/lib/gstreamer-1.0" \
  "/usr/local/lib/gstreamer-1.0"; do
  [[ -d "$gst_dir" ]] && { GST_SRC_DIR="$gst_dir"; break; }
done
if [[ -n "${GST_SRC_DIR}" ]]; then
  echo "  source: ${GST_SRC_DIR}"
  GST_PLUGIN_HITS=0
  GST_PLUGIN_MISSES=""
  for p in ${CX_GST_PLUGINS}; do
    if [[ -f "${GST_SRC_DIR}/${p}.dylib" ]]; then
      cp -Lf "${GST_SRC_DIR}/${p}.dylib" "${WINE_LIB}/gstreamer-1.0/" 2>/dev/null \
        && GST_PLUGIN_HITS=$((GST_PLUGIN_HITS + 1))
    else
      GST_PLUGIN_MISSES="${GST_PLUGIN_MISSES} ${p}"
    fi
  done
  echo "  ${GST_PLUGIN_HITS}/17 of CrossOver's plugin set copied"
  [[ -n "${GST_PLUGIN_MISSES}" ]] && echo "  not in this Homebrew build:${GST_PLUGIN_MISSES}"
else
  echo "  WARN no gstreamer plugin directory found"
fi

echo "=== GStreamer core libs ==="
# Bundle every libgst*.dylib available, rather than a hand-picked six.
# CrossOver.app's lib64/ carries the full set (~40 libs: adaptivedemux, allocators,
# app, audio, base, codecparsers, codecs, controller, fft, gl, isoff, mpegts, mse,
# net, pbutils, play, riff, rtp, rtsp, sdp, tag, video, webrtc, ...) because the
# plugins link against each other, and a plugin that cannot resolve one of these
# silently fails to load with no error from Wine.
#
# Look in the official framework first, then Homebrew.
GST_LIB_SRC=""
for d in "${GST_FRAMEWORK}/lib" "${BREW_PREFIX}/lib"; do
  # Portable "does this glob match anything" check — no compgen, no nullglob
  # side effects: if the glob does not expand, the literal path is not a file.
  for probe in "${d}"/libgst*.dylib; do
    if [[ -f "$probe" ]]; then GST_LIB_SRC="$d"; break; fi
  done
  [[ -n "${GST_LIB_SRC}" ]] && break
done
GST_CORE_COUNT=0
if [[ -n "${GST_LIB_SRC}" ]]; then
  echo "  source: ${GST_LIB_SRC}"
  for candidate in "${GST_LIB_SRC}"/libgst*.dylib; do
    [[ -f "$candidate" ]] || continue
    bundle_dep "$candidate"
    GST_CORE_COUNT=$((GST_CORE_COUNT + 1))
  done
  # glib and friends live next to them inside the framework; pull those too.
  if [[ "${GST_LIB_SRC}" == "${GST_FRAMEWORK}/lib" ]]; then
    for candidate in "${GST_LIB_SRC}"/libglib-2.0*.dylib "${GST_LIB_SRC}"/libgobject-2.0*.dylib \
                     "${GST_LIB_SRC}"/libgio-2.0*.dylib "${GST_LIB_SRC}"/libgmodule-2.0*.dylib \
                     "${GST_LIB_SRC}"/libgthread-2.0*.dylib "${GST_LIB_SRC}"/libffi*.dylib \
                     "${GST_LIB_SRC}"/libintl*.dylib "${GST_LIB_SRC}"/liborc-0.4*.dylib; do
      [[ -f "$candidate" ]] && bundle_dep "$candidate"
    done
  fi
else
  echo "  WARN no libgst*.dylib found — GStreamer was not installed, skipping"
fi
echo "  ${GST_CORE_COUNT} libgst*.dylib considered"
endgroup

group "Rewrite Homebrew load paths to @loader_path"
echo "=== bundled dylibs (lib/*.dylib -> @loader_path/) ==="
for dylib in "${WINE_LIB}"/*.dylib; do
  [[ -f "$dylib" ]] || continue
  while IFS= read -r dep; do
    [[ "$dep" =~ $FOREIGN_RE ]] || continue
    depname=$(basename "$dep")
    [[ -f "${WINE_LIB}/${depname}" ]] || continue
    install_name_tool -change "$dep" "@loader_path/${depname}" "$dylib" 2>/dev/null \
      && echo "  $(basename "$dylib") -> ${depname}"
  done < <(otool -L "$dylib" 2>/dev/null | awk 'NR>1{print $1}')
  true
done

echo "=== loader binaries (bin/* -> @loader_path/../lib/) ==="
find "${WINE_ROOT}/bin" -type f \( -name "wine" -o -name "wine64" -o -name "wineserver" \) \
| while IFS= read -r binary; do
  while IFS= read -r dep; do
    [[ "$dep" =~ $FOREIGN_RE ]] || continue
    depname=$(basename "$dep")
    [[ -f "${WINE_LIB}/${depname}" ]] || continue
    install_name_tool -change "$dep" "@loader_path/../lib/${depname}" "$binary" 2>/dev/null \
      && echo "  bin/$(basename "$binary") -> ${depname}"
  done < <(otool -L "$binary" 2>/dev/null | awk 'NR>1{print $1}')
done || true

echo "=== unix .so modules (lib/wine/x86_64-unix/* -> @loader_path/../../) ==="
find "${WINE_UNIX_LIB}" -name "*.so" | while IFS= read -r sofile; do
  while IFS= read -r dep; do
    [[ "$dep" =~ $FOREIGN_RE ]] || continue
    depname=$(basename "$dep")
    [[ -f "${WINE_LIB}/${depname}" ]] || continue
    install_name_tool -change "$dep" "@loader_path/../../${depname}" "$sofile" 2>/dev/null \
      && echo "  $(basename "$sofile") -> ${depname}"
  done < <(otool -L "$sofile" 2>/dev/null | awk 'NR>1{print $1}')
done || true

echo "=== GStreamer plugins (lib/gstreamer-1.0/*) ==="
find "${WINE_LIB}/gstreamer-1.0" -name "*.dylib" 2>/dev/null | while IFS= read -r plugin; do
  # These were copied with a plain cp, so their own LC_ID_DYLIB still points at
  # Homebrew. Rewrite it for the same reason as in bundle_dep().
  install_name_tool -id "@loader_path/$(basename "$plugin")" "$plugin" 2>/dev/null || true
  while IFS= read -r dep; do
    [[ "$dep" =~ $FOREIGN_RE ]] || continue
    depname=$(basename "$dep")
    if [[ -f "${WINE_LIB}/gstreamer-1.0/${depname}" ]]; then
      install_name_tool -change "$dep" "@loader_path/${depname}" "$plugin" 2>/dev/null
    elif [[ -f "${WINE_LIB}/${depname}" ]]; then
      install_name_tool -change "$dep" "@loader_path/../${depname}" "$plugin" 2>/dev/null
    fi
  done < <(otool -L "$plugin" 2>/dev/null | awk 'NR>1{print $1}')
done || true
echo "  GStreamer plugin paths rewritten"
set -o pipefail
endgroup

group "Unversioned dylib aliases (matching CrossOver.app's lib64)"
# CrossOver.app ships every bundled library twice: the real file plus an
# unversioned SYMLINK next to it — libglib-2.0.0.dylib + libglib-2.0.dylib,
# libffi.8.dylib + libffi.dylib, libgnutls.30.dylib + libgnutls.dylib, and so on
# (verified: `ls -la lib64` shows them as lrwxr-xr-x). Anything that dlopens the
# short name resolves, and the artifact costs nothing extra because they are
# links, not copies.
#
# The rule that reproduces CrossOver's entire set is "strip the last numeric
# component": libglib-2.0.0 -> libglib-2.0, libffi.8 -> libffi,
# libpcre2-posix.3 -> libpcre2-posix, libgstaudio-1.0.0 -> libgstaudio-1.0.
# libSDL2 is the one exception (libSDL2-2.0.0 -> libSDL2) and is handled below.
# libMoltenVK.dylib has no numeric component and correctly gets no alias.
ALIAS_COUNT=0
for f in "${WINE_LIB}"/*.dylib "${WINE_LIB}"/gstreamer-1.0/*.dylib; do
  [[ -f "$f" ]] || continue
  [[ -L "$f" ]] && continue
  dir=$(dirname "$f")
  base=$(basename "$f")
  if [[ "$base" =~ ^(.+)\.[0-9]+\.dylib$ ]]; then
    alias_name="${BASH_REMATCH[1]}.dylib"
    if [[ "$alias_name" != "$base" && ! -e "${dir}/${alias_name}" ]]; then
      ln -s "$base" "${dir}/${alias_name}" 2>/dev/null \
        && ALIAS_COUNT=$((ALIAS_COUNT + 1))
    fi
  fi
done
# SDL2's alias does not follow the numeric rule: CrossOver links
# libSDL2.dylib -> libSDL2-2.0.0.dylib, dropping "-2.0" as well.
if [[ -f "${WINE_LIB}/libSDL2-2.0.0.dylib" && ! -e "${WINE_LIB}/libSDL2.dylib" ]]; then
  ln -s "libSDL2-2.0.0.dylib" "${WINE_LIB}/libSDL2.dylib" 2>/dev/null \
    && { ALIAS_COUNT=$((ALIAS_COUNT + 1)); echo "  libSDL2.dylib -> libSDL2-2.0.0.dylib"; }
fi
echo "  ${ALIAS_COUNT} aliases created"
endgroup

# ---------------------------------------------------------------------------
group "Bundling summary"
DYLIB_COUNT=$(find "${WINE_LIB}" -maxdepth 1 -name "*.dylib" 2>/dev/null | wc -l | tr -d ' ' || true)
GST_COUNT=$(find "${WINE_LIB}/gstreamer-1.0" -name "*.dylib" 2>/dev/null | wc -l | tr -d ' ' || true)
echo "dylibs in wine/lib:              ${DYLIB_COUNT:-0}"
echo "GStreamer plugins in wine/lib:   ${GST_COUNT:-0}"
echo "--- critical libs ---"
for want in libSDL2-2.0.0.dylib libMoltenVK.dylib libfreetype.6.dylib libgnutls.30.dylib libglib-2.0.0.dylib libgstreamer-1.0.0.dylib; do
  if [[ -f "${WINE_LIB}/${want}" ]]; then
    echo "  OK   ${want}"
  else
    echo "  WARN ${want} not bundled"
  fi
done
GST_LIB_COUNT=$(find "${WINE_LIB}" -maxdepth 1 -name "libgst*.dylib" 2>/dev/null | wc -l | tr -d ' ' || true)
echo "  libgst*.dylib bundled: ${GST_LIB_COUNT:-0}  (CrossOver.app ships ~40)"
echo "--- remaining absolute Homebrew references (should be empty) ---"
# `otool -L` on a dylib prints the file name on line 1 and the library's OWN
# LC_ID_DYLIB on line 2, so a naive NR>1 treats each bundled library's own
# install name as a dependency and this report would never come back clean.
# Filter out any entry whose basename equals the file's own basename; the IDs
# themselves are already rewritten at bundle time.
LEAK=$(find "${WINE_ROOT}/bin" "${WINE_UNIX_LIB}" "${WINE_LIB}" -maxdepth 2 -type f 2>/dev/null \
  | while IFS= read -r f; do
      self=$(basename "$f")
      otool -L "$f" 2>/dev/null | awk 'NR>1{print $1}' \
        | grep -E "${FOREIGN_GREP}" \
        | while IFS= read -r dep; do
            [[ "$(basename "$dep")" == "${self}" ]] && continue
            echo "  ${self}: ${dep}"
          done
    done | sort -u | head -20 || true)
if [[ -n "${LEAK}" ]]; then
  echo "${LEAK}"
  echo "  WARN the above still point at Homebrew paths and will fail on a user machine"
else
  echo "  none"
fi
endgroup

# ---------------------------------------------------------------------------
# DXMT is built by the workflow AFTER this script returns, because it needs the
# Wine build tree (${BUILDDIR}) that this script leaves in place. The workflow
# then writes CrossOver's own layout, lib/dxmt/{x86_64-windows,i386-windows,
# x86_64-unix}, plus a share/dxmt/{x86_64,x86} compatibility mirror, and repacks
# the artifact. Pre-create those directories so the workflow's copy steps cannot
# fail on a missing path.
group "Prepare DXMT drop-in directories"
mkdir -p "${WINE_ROOT}/lib/dxmt/x86_64-windows" \
         "${WINE_ROOT}/lib/dxmt/i386-windows" \
         "${WINE_ROOT}/lib/dxmt/x86_64-unix" \
         "${WINE_ROOT}/share/dxmt/x86_64" \
         "${WINE_ROOT}/share/dxmt/x86"
echo "  lib/dxmt/{x86_64-windows,i386-windows,x86_64-unix}   (CrossOver layout)"
echo "  share/dxmt/{x86_64,x86}                              (compat mirror)"
echo "  lib/wine/x86_64-unix                                 (winemetal.so)"
# Leave a breadcrumb so the workflow (and a human) can locate the staged tree
# and the Wine build dir without recomputing the paths.
cat > "${WORKSPACE}/.wine-build-paths" <<EOF
WINE_ROOT=${WINE_ROOT}
BUILDDIR=${BUILDDIR}
STAGEDIR=${STAGEDIR}
ARTIFACT=${ARTIFACT}
CX_VERSION=${VERSION}
EOF
cat "${WORKSPACE}/.wine-build-paths"
endgroup

# ---------------------------------------------------------------------------
group "Package artifact"
rm -f "${ARTIFACT}"
# Top-level directory inside the archive is "wine", giving the requested
# wine/{bin,include,lib,share} layout on extraction.
tar -C "${STAGEDIR}" -cJf "${ARTIFACT}" wine
ls -lh "${ARTIFACT}"
echo "--- archive top level ---"
tar -tJf "${ARTIFACT}" | awk -F/ '{print $1"/"$2}' | sort -u | head -10 || true
endgroup

echo
echo "Done."
echo "  CrossOver source : ${VERSION} ($(cat "${WINE_SRC}/VERSION"))"
echo "  CrossOver hacks  : ${HACK_SITES:-0} sites, ${HACK_IDS:-0} distinct CW bug IDs (all pre-applied)"
echo "  Patches added    : none — pure CrossOver source"
echo "  Artifact         : ${ARTIFACT}"









