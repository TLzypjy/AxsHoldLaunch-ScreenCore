#!/bin/sh
# Repackage the clean 2.0.5+holdpress.1 base with the beautify panel overlay
# (SplitSettings.plist + two SplitSettings.strings) and the freshly built
# AxsHoldLaunch.dylib, then verify with dpkg-deb.
#
# Inputs:
#   AXS_DYLIB  - path to the rootless AxsHoldLaunch.dylib from the CI build
# Output:
#   out/com.susudear.screencore_2.0.5+beautify.1_iphoneos-arm64.deb
set -eu
cd "$(dirname "$0")"

VERSION="2.0.5+beautify.137"
BASE_DEB="base/com.susudear.screencore_2.0.5+holdpress.1.deb"
OUT="out"
PKG="$OUT/pkg"

if [ -z "${AXS_DYLIB:-}" ] || [ ! -f "$AXS_DYLIB" ]; then
    echo "ERROR: AXS_DYLIB not set or missing" >&2
    exit 1
fi
if [ ! -f "$BASE_DEB" ]; then
    echo "ERROR: base deb missing: $BASE_DEB" >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$PKG/DEBIAN"

# 1) baseline data + control (ScreenCore dylibs and the prefs bundle binary
#    stay exactly as shipped by 2.0.5+holdpress.1)
dpkg-deb -x "$BASE_DEB" "$PKG"
dpkg-deb -e "$BASE_DEB" "$PKG/DEBIAN"
rm -f "$PKG/DEBIAN/control"

# 2) overlay: the three patched files in ScreenCorePrefs.bundle
BUNDLE="$PKG/var/jb/Library/PreferenceBundles/ScreenCorePrefs.bundle"
cp overlay/SplitSettings.plist                     "$BUNDLE/SplitSettings.plist"
cp overlay/zh-Hans.lproj/SplitSettings.strings     "$BUNDLE/zh-Hans.lproj/SplitSettings.strings"
cp overlay/en.lproj/SplitSettings.strings          "$BUNDLE/en.lproj/SplitSettings.strings"

# 3) our module dylib from this CI build; filter plist stays the baseline's
DYLIB_DIR="$PKG/var/jb/Library/MobileSubstrate/DynamicLibraries"
cp "$AXS_DYLIB" "$DYLIB_DIR/AxsHoldLaunch.dylib"

# 4) control: field lines only, clean Description continuation
SIZE=$(find "$PKG" -type f -not -path "*/DEBIAN/*" -exec stat -f%z {} + | awk '{s+=$1} END {printf "%d", int(s/1024)+1}')
{
    echo "Package: com.susudear.screencore"
    echo "Name: ScreenCore"
    echo "Description: 分屏而已"
    echo " 接通光圈自定义取色：颜色行/色块点击打开系统取色器（支持 alpha，写回 #RRGGBB(AA) 即时刷新存活环）；自定义开关 ON=所选单色，OFF=彩虹跑马灯。"
    echo "Maintainer: SuSu"
    echo "Author: SuSu"
    echo "Icon: https://repo.susubaby.cn/icons/ScreenCore.png"
    echo "Section: Tweaks"
    echo "Depends: mobilesubstrate, preferenceloader, com.opa334.altlist"
    echo "Architecture: iphoneos-arm64"
    echo "Version: $VERSION"
    echo "Installed-Size: $SIZE"
} > "$PKG/DEBIAN/control"

# 5) permissions: dirs 0755, files 0644, dylibs + usr/libexec binaries 0755
find "$PKG" -type d -exec chmod 755 {} +
find "$PKG" -type f -exec chmod 644 {} +
find "$PKG" -name "*.dylib" -exec chmod 755 {} +
chmod 755 "$PKG/var/jb/usr/libexec/screencore-userspace-reboot"

# 6) sanity checks before packing (labeled, so a failure says which one)
check() {
    # check <label> <cmd...>
    label=$1; shift
    if ! "$@"; then
        echo "ERROR: sanity check failed: $label" >&2
        exit 1
    fi
}
check "filter has springboard" sh -c "plutil -p '$DYLIB_DIR/AxsHoldLaunch.plist' | grep -q 'com.apple.springboard'"
check "filter has preferences" sh -c "plutil -p '$DYLIB_DIR/AxsHoldLaunch.plist' | grep -q 'com.apple.Preferences'"
check "plist has beautify switches" sh -c "plutil -p '$BUNDLE/SplitSettings.plist' | grep -q 'splitBeautifyRingFrameEnabled'"
check "plist has beautify sliders" sh -c "plutil -p '$BUNDLE/SplitSettings.plist' | grep -q 'splitBeautifyGlowRadius'"
check "plist has glow brightness slider" sh -c "plutil -p '$BUNDLE/SplitSettings.plist' | grep -q 'splitBeautifyGlowBrightness'"
check "zh strings localized" sh -c "plutil -p '$BUNDLE/zh-Hans.lproj/SplitSettings.strings' | grep -q '美化'"
check "en strings localized" sh -c "plutil -p '$BUNDLE/en.lproj/SplitSettings.strings' | grep -q 'Beautify'"
check "dylib has beautify color key" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'splitBeautifyRingFrameColor'"
check "dylib has color picker" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'UIColorPickerViewController'"
check "dylib has glow enabled key" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'splitBeautifyGlowEnabled'"
check "dylib has glow custom key" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'splitBeautifyGlowCustomEnabled'"
check "dylib has glow color key" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'splitBeautifyGlowColor'"
check "dylib has glow radius key" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'splitBeautifyGlowRadius'"
check "dylib has glow brightness key" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'splitBeautifyGlowBrightness'"
check "dylib has decor master key" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'splitBeautifyDecorEnabled'"
check "dylib has real picker finish handler" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'colorPickerViewControllerDidFinish:'"
check "dylib has real picker select-color handler" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'colorPickerViewControllerDidSelectColor:'"
check "dylib has no overlay engine marker" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'ring engine start') -eq 0"
check "dylib has no overlay window marker" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'ring window frame') -eq 0"
check "dylib has no overlay window class" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'AXSRingOverlayWindow') -eq 0"
check "dylib has no sc_sessionDidBeginHosting selector" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'sc_sessionDidBeginHosting:') -eq 0"
# beautify.97+: the dismiss-particle module hooks sc_closeSession: via
# NSSelectorFromString (original behaviour untouched), so the old reverse
# "no sc_closeSession selector" assertion is intentionally replaced.
check "dylib has dismiss module load log (beautify.137)" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'DME module loaded in SpringBoard'"
check "dylib has dismiss log path" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'Documents/sc-dismiss-effect.log'"
check "dylib has dismiss switch key" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'splitBeautifyDismissAnimEnabled'"
check "dylib has dismiss emit gpu log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'emit: gpu engine active'"
check "dylib has dismiss style key" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'splitBeautifyDismissStyle'"
# beautify.137: unified GPU engine for all styles (no CPU layer path anymore)
check "dylib has dismiss density key" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'splitBeautifyDismissDensity'"
check "dylib has no UIView CPU emit path" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'CGImageCreateWithImageInRect') -eq 0"
# beautify.106/.107: Metal command queue fix (buffer comes from the queue)
check "dylib has Metal cleanup log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'metal sand cleaned grains='"
# beautify.104: GPU Metal fine-sand engine markers
check "dylib has Metal shader compile log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'metal compiled OK pipeline ready'"
check "dylib has Metal unified start log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'metal started open='"
# beautify.137: ARC-open assemble animation markers
check "dylib has open assemble entry" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'OPEN assemble started'"
check "dylib has open switch key" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'splitBeautifyOpenAnimEnabled'"
check "dylib has finger-source assemble" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'OPEN assemble started duration'"
check "dylib has sendEvent tracking" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'OPEN INSTALL sendEvent'"
check "dylib has native animation replaced log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'OPEN native animation replaced'"
check "dylib has open hook install log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'OPEN INSTALL'"
# beautify.137: reference-plugin selector that actually exists on the device
check "dylib has Metal commandBuffer selector" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'commandBuffer'"
# beautify.95: sc_* selectors are now probed for EXISTENCE only (NSSelectorFromString
# + class_getInstanceMethod in axs_ring_probeNativeChainOnce), never hooked. Assert the
# native-chain probe log is compiled in instead of forbidding the selector string.
check "dylib has native chain probe log (beautify.95)" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring native chain probe'"
check "dylib has no sc_sessionForContainerView selector" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'sc_sessionForContainerView:') -eq 0"
check "dylib has ring log path" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'Documents/sc-ring.log'"
check "dylib has zero-session-hook startup log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring hooks ring=0 sessionHooks=0 layout='"
check "dylib has scan attach log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring attach: scan container=%p'"
check "dylib has scan detach log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring detach: scan container=%p'"
check "dylib has displayLink driver" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'AXSRingLinkDriver'"
check "dylib has whole-frame mask probe" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring probe: mask class=%@ bbox=%@ radius=%.1f'"
check "dylib has radius conversion attach fields" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'rRing=%.1f source=%@ curve=%@'"
check "dylib has mount layer attach fields" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'realFrame=%@ convRect=%@ corner=%.1f'"
check "dylib has real clip finder" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'realCorner'"
check "dylib has layout hook install log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring layout hook installed on SCFloatingContainerView'"
check "dylib has tree probe" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring tree: window=%@ frame=%@ bounds=%@'"
check "dylib has no AXSRingFrame class" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'AXSRingFrame') -eq 0"
check "dylib has rotation marquee (z keypath)" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'transform.rotation.z'"
# beautify.96: fullscreen probe (STEP 0, log-only). The old reverse assertion
# "dylib has no fullscreen selectors" is intentionally removed: the probe now
# installs MSHookMessageEx hooks on the large-floating -> fullscreen chain to
# LOG call order / source frame / completion timing only (never changes behavior).
# Assert the probe markers are compiled in instead.
check "dylib has fullscreen probe load log (beautify.96)" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'FSP module loaded in SpringBoard'"
check "dylib has fullscreen probe log path" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'Documents/sc-fullscreen-probe.log'"
check "dylib has fullscreen probe argsSafe guard" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'argsSafe='"
check "dylib has fullscreen promoteSession hook" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'promoteSceneToFullscreenForSession'"
check "dylib has holdpress log in Documents" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'Documents/AxsHoldLaunch.log'"
check "dylib has no Caches log path left" sh -c "test \$(strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -c 'Caches/AxsHoldLaunch.log') -eq 0"
# beautify.95: diagnostic probe logs compiled into the dylib (指令 二/三/四/五/八)
check "dylib has tilt PREFS dual-source log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring tilt PREFS plistPath='"
check "dylib has tilt DOCK multi-state log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring tilt DOCK container='"
check "dylib has tilt HIERARCHY dump log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring tilt HIERARCHY root='"
check "dylib has native base transform reader" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'originalHostTransform'"
# beautify.95: visual-host isolation fix compiled into dylib (content root, overlay planar, residual log)
check "dylib has tilt VISUAL HOSTS (beautify.95) log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring tilt VISUAL HOSTS (beautify.95)'"
check "dylib has scene content root class" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q '_UIScenePresentationView'"
check "dylib has reset residual log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'residual(m13='"
# beautify.95: wrapper hosts + remote-root ban + clip release compiled into dylib
check "dylib has REMOTE_SCENE_ROOT marker" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'REMOTE_SCENE_ROOT'"
check "dylib has CONTENT_WRAPPER marker" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'CONTENT_WRAPPER'"
check "dylib has HOST_EVICTED restore log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring tilt HOST_EVICTED'"
# beautify.95: cleanBase state machine + corner mask + safe abort compiled into dylib
check "dylib has BASE_CLEAN log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring tilt BASE_CLEAN'"
check "dylib has SAFE_ABORT log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring tilt SAFE_ABORT'"
check "dylib has CORNER_CLIP log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring tilt CORNER_CLIP'"
check "dylib has ZORDER log" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'ring tilt ZORDER'"
check "dylib has plugin corner mask name" sh -c "strings -a '$DYLIB_DIR/AxsHoldLaunch.dylib' | grep -q 'AxsTiltCornerMask'"

# 7) package rootless (+ roothide hidden-root variant)
DEB="$OUT/com.susudear.screencore_${VERSION}_iphoneos-arm64.deb"
dpkg-deb --root-owner-group -b "$PKG" "$DEB"
echo "=== dpkg-deb -I ==="
dpkg-deb -I "$DEB"
echo "=== dpkg-deb -c ==="
dpkg-deb -c "$DEB"
echo "=== packaged: $DEB ==="

# 8) roothide (多巴胺隐根) variant -- produced by the OFFICIAL RootHide Patcher
# script (packaging/roothide/patch.sh, pinned @ roothide/RootHidePatcher b3e04a4aaa98).
#
# Why the official script instead of a hand-rolled repack: a plain layout flattening
# is NOT the full conversion. patch.sh additionally
#   a) rewrites every Mach-O rpath /var/jb/X -> @loader_path/.jbroot/X
#   b) re-signs every Mach-O with ldid
#   c) in AutoPatches mode ("Rootless 兼容层" in the on-device app) writes a
#      <mach-o>.roothidepatch marker symlink + Pre-Depends: rootless-compat so the
#      bootstrap's Dynamic Patch Framework remaps hardcoded paths at load time.
# A hand-flattened package missing these broke tweak init on device (Arc menu dead).
# Running the same script the on-device Patcher runs guarantees identical output.
RH_DEB="$OUT/com.susudear.screencore_${VERSION}_iphoneos-arm64e-roothide.deb"
# NOTE: the script cd'd into its own dir at the top, so cwd == packaging/
SCRIPT_DIR="$(pwd)"
bash "$SCRIPT_DIR/roothide/patch.sh" "$DEB" "$RH_DEB" AutoPatches
test -f "$RH_DEB" || { echo "roothide conversion produced no deb"; exit 1; }
echo "=== roothide dpkg-deb -I ==="
dpkg-deb -I "$RH_DEB"
echo "=== roothide dpkg-deb -c ==="
dpkg-deb -c "$RH_DEB"
echo "=== packaged roothide: $RH_DEB ==="
ls -la "$OUT"
