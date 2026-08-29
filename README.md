# Wine building — CrossOver source

Builds **the Wine that CrossOver ships**, straight from the CodeWeavers source drop,
with **every CrossOver patch included** — because the source drop *is* the patched tree.

Exactly one thing is layered on top, and only if you ask for it: the Steam web-helper CEF
hack (CW 13322/17315/21883), which CodeWeavers carried in the CX20-era tree and dropped
before CX26. See [The Steam CEF hack](#the-steam-cef-hack).

Replaces the old `CROSSOVER sources/my wine build script/` pipeline, which built vanilla
WineHQ and hand-applied ~20 CrossOver patches from a third-party macports repo.

## Files

| File | What it is |
|---|---|
| `build-wine-crossover.sh` | The build. Takes one argument: the CrossOver version. |
| `build-wine-crossover.yml` | Manual-dispatch GitHub Actions workflow. **Copy to `.github/workflows/`** — GitHub only runs workflows from there. |
| `patches/0001-kernelbase-steamwebhelper-cef.patch` | The Steam CEF hack. Off by default. **Must be committed next to the script** — the workflow's pre-flight fails in seconds if it is missing. |

## Running it

Actions → **Build CrossOver Wine (DXMT)** → *Run workflow*:

| Input | Default | Notes |
|---|---|---|
| `cx_version` | `26.3.0` | **Free text** — type any version, e.g. `26.2.0`. Validated as digits-and-dots and then range-checked against `media.codeweavers.com` before anything compiles. Verified serving: 26.3.0, 26.2.0, 26.1.0, 26.0.0. |
| `steam_cef_hack` | `false` | Apply the Steam web-helper CEF patch. Turn this **on** if Steam's login window is black with clickable buttons. |
| `dxmt_ref` | `main` | DXMT branch or tag. |
| `make_release` | `true` | Off = artifact upload only, no release tag. |

With `steam_cef_hack` on, the release tag gains a `-steamcef` suffix so the two variants can
coexist and be A/B'd with one variable changed.

Output: **`wine-crossover-<version>-osx64.tar.xz`**, extracting to

```
wine/
  bin/  include/  lib/  share/
```

Install it through the launcher's Wine manager like any other build. No launcher code
changes are needed — the installer already recurses to find `wine64`/`wine`, and DXMT lands
in the paths `ensureDxmtInBottle()` already reads.

## Controllers and Bluetooth rumble — read this before touching the SDL bits

**Never `brew install sdl2`.** Homebrew's `sdl2` is an alias for `sdl2-compat`: the SDL2 API
reimplemented on top of SDL3, which `dlopen`s `libSDL3.dylib` at runtime. Wine's `configure`
accepts it (identical soname, identical headers), the build goes green, and the shipped
artifact then **aborts inside `SDL_Init()`** on any machine without SDL3.

Measured on a real install of a build that made this mistake:

| | CrossOver.app 26.3.0 | the broken build |
|---|---|---|
| `libSDL2-2.0.0.dylib` | 1,366,544 B, `SDL-release-2.30.12-0-g8236e01a9` | 375,408 B, `sdl2-compat` |
| links | CoreAudio, CoreHaptics, GameController, ForceFeedback | AppKit/Foundation only |
| needs SDL3 at runtime | no | **yes**, and nothing bundles it |

The user-visible symptom is not "no rumble", it is **no controller at all** — because
`dlls/winebus.sys/main.c:1271` also shuts the IOHID bus down when `DisableHidraw=1`. So with
*Disable Hidraw* on, a dead SDL bus leaves the bottle with no gamepad bus whatsoever. Exactly
the observed matrix: SDL on + hidraw off → nothing; SDL off + hidraw on → nothing; both off →
detected (IOHID only, no XInput mapping, no BT rumble).

The workflow therefore **builds SDL 2.30.12 from the upstream release tarball** into
`/usr/local` (~1–2 min with ninja), unlinks any `sdl2-compat` keg first, and puts
`/usr/local/lib/pkgconfig` at the front of `PKG_CONFIG_PATH`. Four gates make a regression
impossible to ship quietly:

1. right after the SDL build — reject if `strings` says `sdl2-compat`;
2. toolchain pre-flight — `pkg-config --modversion sdl2` must be `2.x`, and the dylib must
   not be sdl2-compat;
3. post-configure — `SONAME_LIBSDL2` **must** be defined in `config.h` (fatal, was a warning);
4. before packaging *and* again on the published tarball — real SDL2 version string present,
   no SDL3 reference, `winebus.so` records `libSDL2-2.0.0.dylib`, and `xbox_bus_init` (from
   CrossOver's own `bus_xbox360.c`) is present.

The rumble path itself is CrossOver's, unmodified: `bus_sdl.c:1154` is CW HACK 19629, "Enable
rumble over BT for PS4/PS5 controllers", and `main.c:397-402` / `542-543` carry the
DS4/DualSense handling.

**Acceptance test:** Enable SDL = on, Disable Hidraw = on, DS4 paired over Bluetooth → the
pad appears as an XInput gamepad and rumbles in ETS2.

## The Steam CEF hack

Verified absent from `crossover-sources-26.3.0` and `26.1.0`: no `hack_append_command_line`,
no `steamwebhelper` anywhere in `dlls/`. Also confirmed absent from the shipped
`CrossOver.app` binaries. It *is* present in the old macports-based build — the check has to
search **UTF-16LE**, since these are `L"..."` wide literals and plain `strings` finds nothing:

```
tr -d '\000' < lib/wine/x86_64-windows/kernelbase.dll | grep steamwebhelper
```

What it does: appends `--no-sandbox --in-process-gpu --disable-gpu` to `steamwebhelper.exe`,
skipping `--type=crashpad-handler`. Without it, the web helper starts with GPU compositing
on, CEF never presents through `winemac.drv`, and the login window paints black while the DOM
stays live and clickable. Chromium then latches
`gpu.hardware_acceleration_mode.enabled=false` into `htmlcache/Local State`, which is why the
failure is permanent after the first launch.

Reconstructed from `riverfog7/macports-wine` (branch `patches`) files `0004-kernelbase-HACK-
Add-hack_append_command_line.diff` + `0005-kernelbase-CW-HACK-13322-17315-21883.diff` and
rebased onto CX26's `CreateProcessInternalW`, which now carries CW Hack 24938 (Epic) and CW
Hack 24920/24557 (powershell) between the `app_name` resolution and the "Warn if unsupported
features" block. Two deliberate fixes versus the originals, both documented in the patch
header: the allocation is sized from `tidy_cmdline` rather than `cmd_line` (the originals size
from one and copy the other — a heap overflow in the quoted-`app_name` case), and
`hack_append_command_line()` returns early on a NULL `cmd_line`.

`1001-kernelbase-CW-HACK-19610.diff` (Battle.net) is deliberately not included.

### If the black screen persists with the hack on

Two bottle-side things were measured against CrossOver's own working Steam bottle and are
*not* fixable from the Wine build:

- `…/htmlcache/Local State` — CrossOver: `gpu` and `hardware_acceleration_mode` **absent**,
  `hardware_acceleration_mode_previous: true`. A latched
  `{"enabled": false}` there keeps CEF's compositor off no matter what Wine does. Note the
  bottle can hold **two** copies, under `users/crossover/` and `users/<you>/`.
- DXMT's `dxgi.dll` / `d3d11.dll` / `d3d10core.dll` sitting in the bottle's `system32` /
  `syswow64`. CrossOver's Steam bottle has Wine's **builtin** dxgi (218 KB) there, not DXMT
  (1.89 MB). Wine resolves by directory, so `steamwebhelper` picks DXMT up even though the
  launcher deliberately sets no `WINEDLLOVERRIDES` for Steam — the `STATUS_BREAKPOINT` path
  `CLAUDE.md` warns about, and what makes CEF write that pref in the first place.

Also worth knowing: the launcher writes `MaxVersionGL=4.1` and `MultiThreadedGL=N` under
`HKCU\Software\Wine\Mac Driver`, and **nothing reads them** — not CrossOver's source (`grep`
over `dlls/` hits only `wined3d/wined3d_main.c:359`, a different key) and not any of the three
`winemac.so` binaries compared, the old macports build included. CrossOver's working bottle
sets neither. They are inert, not the fix.


## What's in the box

- Wine **11.0** as patched by CrossOver — **260 CrossOver hack sites across 89 files,
  76 distinct CW bug IDs**. The build asserts this count and fails if it's under 100, which
  catches a truncated download before the 40-minute compile rather than after. It also
  checks 14 CW bug IDs by name, and hard-fails if **CW 22435** (winemac D3DMetal) is absent,
  since DXMT depends on it.
- **GStreamer** — every `libgst*.dylib` Homebrew installs, plus the plugins, matching the
  ~40-library set CrossOver.app carries in its `lib64/`. A plugin that can't resolve one of
  its siblings fails to load silently, with no error from Wine, so the whole set is bundled
  rather than a hand-picked handful.
- **SDL2** — **real SDL 2.30.12**, built from source, plus a `libSDL2.dylib` alias, exactly as
  CrossOver.app ships them. This is not decoration: `dlls/winebus.sys` compiles `bus_sdl.c`
  and uses `SDL2_CFLAGS`, so SDL2 is how gamepads, joysticks and Bluetooth rumble work. Wine
  `dlopen`s it by soname (`libSDL2-2.0*`), and it lands in `wine/lib`, which is on the
  `DYLD_FALLBACK_LIBRARY_PATH` that `standaloneWineEnv()` already sets. **Not** Homebrew's
  `sdl2` — that is `sdl2-compat`, and it breaks controllers outright.
- gnutls, FreeType, the glib stack (glib/gobject/gio/gmodule/gthread, libffi, libintl,
  libpcre2), MoltenVK, CoreAudio, OpenCL — copied into `wine/lib` with both their
  `LC_LOAD_DYLIB` entries **and** their own `LC_ID_DYLIB` rewritten to `@loader_path`, so
  nothing points back at a Homebrew path that won't exist on a user's machine.
- **DXMT**, built against this Wine tree: `wine/lib/wine/x86_64-unix/winemetal.so` (and a
  `.dylib` copy of the same file) plus `wine/share/dxmt/x86_64/` and `wine/share/dxmt/x86/`.

### Dependency sources — verified 2026-08-28, do not "fix" these

**GStreamer does not come from Homebrew, and the reason is one specific formula.**

`brew install gstreamer` pulls 61 direct dependencies. One of them, **`pygobject3` 3.58.0**,
has bottle tags `arm64_linux, arm64_sequoia, arm64_sonoma, arm64_tahoe, x86_64_linux` —
**no macOS Intel bottle at all**, not even `sonoma`. On an Intel runner brew must therefore
build it from source, and that is what fails.

This is a recent regression, not a mistake in the old build script. Homebrew 6.0 (June 2026)
moved macOS Intel to Tier 3 — "no CI support and no new bottles built for macOS Intel" from
September 2026 — and a maintainer confirmed *"we are winding down support for Intel and will
no longer be doing any mass bottling for that platform."* `gstreamer` itself still has an
Intel `sonoma` bottle, and Homebrew falls back to the nearest older Intel bottle happily
(that's how `mingw-w64`, `bison`, `ccache` and `sdl2-compat` install here). It's only
`pygobject3`, with no Intel bottle whatsoever, that has no fallback to take.

So GStreamer comes from the **project's official Universal (x86_64 + ARM64) `.pkg`** instead —
same version, 1.28.6, no architecture problem, no dependency tree at all:

```
https://gstreamer.freedesktop.org/data/pkg/osx/1.28.6/gstreamer-1.0-1.28.6-universal.pkg
https://gstreamer.freedesktop.org/data/pkg/osx/1.28.6/gstreamer-1.0-devel-1.28.6-universal.pkg
```

It installs to `/Library/Frameworks/GStreamer.framework/Versions/1.0` with `lib/pkgconfig`
and carries every plugin CrossOver ships. Because its dylibs have absolute install names
under `/Library/Frameworks`, that prefix is in the bundling and `install_name_tool` rewrite
passes alongside `/usr/local` and `/opt/homebrew`.

**GStreamer is non-fatal.** If it can't be installed, the build continues and `--with-gstreamer`
is simply not passed — Wine 11 still has `winedmo` (FFmpeg) for demuxing. An explicit
`--with-X` turns Wine's "not found" *notice* into a hard configure error, which is exactly
how a missing GStreamer would otherwise burn a whole run.

**On the old formula names:** `sdl2`, `gst-plugins-base/-good/-bad`, `pkg-config` and
`pkgconfig` all return 404 from the formula JSON API, but they still work with
`brew install` — Homebrew resolves them through `aliases`/`oldnames` (`sdl2` → `sdl2-compat`,
the three `gst-plugins-*` → `gstreamer`, `pkg-config`/`pkgconfig` → `pkgconf`). This build
uses the canonical names anyway, so the mapping can't be deprecated out from under it — and
in SDL's case it does not use Homebrew at all, because that alias is precisely the trap
(`sdl2` → `sdl2-compat` → needs SDL3 → no controller).

Most remaining formulae have only an Intel `sonoma` bottle, not `sequoia`. That's fine, per
the fallback above.

The workflow installs **one formula per `brew install` call**, with output *not* folded into a
`::group::` so a failure is visible without expanding anything, then hard-gates on the nine it
can't build without. It also `brew unlink sdl2-compat` if the runner image carries one, so its
keg cannot win the `sdl2` pkg-config lookup.


## Why (almost) no patches are applied

CrossOver's source tarball ships already patched, so there is nothing to apply. It is a
strict superset of what the old build reconstructed by hand:

| Old build did this by hand | CrossOver source already has it |
|---|---|
| Force-apply `0006-winemac-CW-HACK-22435.diff` | CW 22435 native |
| Inject `d3dmetal_objc.m` into `winemac.drv/Makefile.in` | Already in `SOURCES` |
| Synthesise a `macdrv_client_surface_create()` wrapper | Real function, `window.c:1218`, declared `macdrv.h:215` |
| Inject the `d3dmetal_client_surface` ivar | Native |
| Inject a `setFrameSize:` Metal-resize hook | `WineMetalLayer` handles it |
| Define `is_rosetta2` in `signal_x86_64.c` | Native |
| Patch in `winemetal` stubs | `macdrv_functions` is `DECLSPEC_EXPORT` at `d3dmetal.c:397`, ABI-locked by `C_ASSERT(sizeof == 192)` |

Re-adding any of those now would conflict with the real code. The build verifies each of
those pieces is present before compiling, and gates on `macdrv_functions` actually being
exported from the built `winemac.so` — if it isn't, DXMT's `dlsym` fails at runtime with no
error message at all, so it's worth catching in CI.

The **one** exception is the Steam web-helper CEF hack, which CodeWeavers genuinely dropped
before CX26 rather than moved. It is opt-in — see
[The Steam CEF hack](#the-steam-cef-hack) — and the artifact check fails the run if the
hack's presence does not match the requested setting, in either direction, so a "pure
CrossOver" build can never quietly contain it.

## Differences from the old build script

**OpenGL is no longer disabled.** The old script passed `--without-opengl`. It could only
get away with that because its steamwebhelper hack forced `--disable-gpu`, so Steam's CEF
rendered in software and never asked for a GL context. This build passes neither
`--with-opengl` nor `--without-opengl`, letting configure auto-detect and enable it — which
is what CrossOver does, and CrossOver.app runs Steam correctly. The post-configure step
reports what configure actually decided. **If Steam ever regresses, this is the first thing
to check.**

**SDL is no longer disabled, and it must be real SDL2.** The old script passed
`--without-sdl` while still bundling `libSDL2`, which is contradictory: with that flag,
`bus_sdl.c` compiles to a no-op and the bundled dylib is never loaded, so there is no SDL
gamepad path at all. That is very likely why a separate `DYLD_INSERT_LIBRARIES` SDL2 preload
was needed. The flag is now omitted so configure detects SDL2 and defines `SONAME_LIBSDL2` —
which is now a **fatal** check, not a warning. The SDL2 itself is built from the upstream
2.30.12 tarball rather than installed from Homebrew; see
[Controllers and Bluetooth rumble](#controllers-and-bluetooth-rumble--read-this-before-touching-the-sdl-bits)
for why that distinction is the difference between a working controller and none.

Neither flag is passed as `--with-…`: an explicit `--with-x` turns Wine's "not found"
*notice* into a hard configure error, so an unrelated detection hiccup would kill the run.
Omitting them lets configure decide, and the checks report what it chose.

**Architecture is x86_64 and that is not a preference.** `dlls/winemac.drv/d3dmetal_objc.h`
is wrapped in `#if defined(__x86_64__)`, so CrossOver's entire Metal/D3DMetal bridge
compiles out on arm64. The workflow runs on `macos-15-intel` and builds
`--enable-archs=i386,x86_64`, which runs under Rosetta 2 on Apple Silicon. Same as
CrossOver.

## Parity with CrossOver.app

Measured against a real install of
`/Applications/CrossOver.app/Contents/SharedSupport/CrossOver`.

**Matched exactly:**

| Thing | CrossOver | This build |
|---|---|---|
| Bundled non-gst dylibs | SDL2, MoltenVK, freetype, gnutls, gmp, glib/gobject/gio/gmodule/gthread, ffi, intl, pcre2-8, pcre2-posix | same set |
| `libgst*` core libs | 32 | every one Homebrew provides |
| GStreamer plugins | a curated **17** (`applemedia asf audioconvert audioparsers audioresample avi coreelements deinterlace id3demux isomp4 opengl playback typefindfunctions videoconvertscale videofilter videoparsersbad wavparse`) | the same 17 by name, not Homebrew's ~120 |
| Unversioned aliases | symlinks (`libglib-2.0.dylib -> libglib-2.0.0.dylib`, `libSDL2.dylib -> libSDL2-2.0.0.dylib`, …) | same, as symlinks, via "strip the last numeric component" + the SDL2 special case |
| DXMT layout | `lib/dxmt/{x86_64-windows, i386-windows, x86_64-unix}` | same, plus a `share/dxmt/{x86_64,x86}` mirror |
| PE DLLs | 785 x86_64-windows / 845 i386-windows | reported and compared each run |
| Unix modules | 34 in `lib/wine/x86_64-unix` | reported and diffed each run |

**Cannot match, and why:**

| Missing | Reason |
|---|---|
| `cxcompatdb.so`, `winelib.so` | CodeWeavers-only. No `dlls/cxcompatdb` or `dlls/winelib` in the public source drop |
| `winebth.so` | No `dlls/winebth` in this source drop |
| `libinotify.0.dylib` | Not in Homebrew. CodeWeavers build macports' libinotify-kqueue themselves, so `--without-inotify` stays |
| `lib64/apple_gptk/` (`D3DMetal.framework`, `libd3dshared.dylib`) | Proprietary Apple Game Porting Toolkit, licensed to CodeWeavers. **DXMT is the substitute** — that's the whole point of this build |
| `lib/dxvk/` | Not built here; DXMT covers D3D11 for ETS2/ATS |
| `share/wine/gecko`, `share/wine/mono` | CrossOver pre-bundles wine-gecko 2.47.4 (x86 + x86_64) and wine-mono 10.4.1. `make install` doesn't produce them; Wine fetches them on demand at prefix creation. Not needed for ETS2/ATS |
| `kerberos.so`, `netapi32.so` | This build passes `--without-krb5` / `--without-netapi`, inherited from the previously working configuration. Flip those two flags if you want them — but they can hard-fail configure, so they were left alone deliberately |
| `bin/cx*` tools, perl, python, ghostscript, cabextract, unrar | CrossOver application plumbing, not Wine |

**One structural difference by design:** CrossOver splits host dylibs into `lib64/` and Wine
modules into `lib/wine/`. This build uses the standard Wine layout — host dylibs in
`wine/lib`, modules in `wine/lib/wine/` — because that's what the `-rpath` entries and the
launcher's `standaloneWineEnv()` expect (it puts `dirname(wine)/../lib` on
`DYLD_FALLBACK_LIBRARY_PATH`). Same files, one directory level different.

The other unavoidable difference: this build's deps come from Homebrew, so it also bundles
`nettle`, `hogweed`, `tasn1`, `idn2`, `unistring`, `p11-kit` and `orc`, which CrossOver does
not ship separately — CodeWeavers build gnutls and GStreamer with those linked in
statically. Dropping them would break gnutls at runtime here.

## Build time


First run ~2h15m, mostly LLVM 15 (~30-40 min, cached afterwards) and Wine itself
(~45-70 min, ccache-warmed afterwards). Later runs of the same version ~35-50 min.
SDL 2.30.12 adds ~1-2 min. Toggling `steam_cef_hack` uses a separate ccache key, so the
first build of each variant pays a cold-ish cache.

## Notes for whoever touches this next

- Only `sources/wine` is extracted from the 149 MB tarball. The other ~15 dependency trees
  (ghostscript, gstreamer, glib, moltenvk, …) are ignored — those come from Homebrew.
- `make install`, never `make install-image`. CrossOver appends an `install-image` rule in
  `configure.ac` that renames `bin/wine` to `bin/wineloader`; the launcher looks for
  `wine64`/`wine` by name.
- `--prefix=` is deliberately empty so `make install DESTDIR=…` lays down
  `bin/ include/ lib/ share/` directly. Wine resolves its own runtime paths relative to the
  loader via `dladdr` on macOS, so this is safe.
- `MultiThreadedGL`, which the launcher writes into `user.reg`, is **not read by anything in
  CrossOver's Wine**. `MaxVersionGL` is read only by `wined3d_main.c`, not by `winemac.drv`.
  Neither is wrong to keep writing, but neither does what the comment in `main.js` implies
  against this Wine.
