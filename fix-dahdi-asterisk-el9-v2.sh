#!/usr/bin/env bash
#
# fix-dahdi-asterisk-el9.sh
#
# Safe DAHDI + Asterisk 18 helper for EL9/RHEL9/Alma/Rocky systems.
#
# IMPORTANT DESIGN CHOICES FOR THIS SERVER:
#   - Asterisk source default:
#       /usr/src/asterisk/asterisk-18.21.0-vici
#   - Existing production module directory:
#       /usr/lib64/asterisk/modules
#   - Existing third-party modules such as codec_g729.so are PRESERVED.
#   - We DO NOT run "make install" for the whole Asterisk tree.
#     We build chan_dahdi.so and copy only the required DAHDI-related
#     modules into the existing production module directory.
#   - Bundled PJPROJECT is disabled during this targeted build so an
#     offline server does not attempt to download PJPROJECT.
#
# Usage:
#   chmod +x fix-dahdi-asterisk-el9.sh
#   ./fix-dahdi-asterisk-el9.sh
#
# Non-interactive restart:
#   ./fix-dahdi-asterisk-el9.sh --yes
#
# Override paths if required:
#   DAHDI_SRC=/usr/src/dahdi-linux-complete-3.4.0+3.4.0 \
#   ASTERISK_SRC=/usr/src/asterisk/asterisk-18.21.0-vici \
#   ./fix-dahdi-asterisk-el9.sh
#

set -Eeuo pipefail

DAHDI_SRC="${DAHDI_SRC:-/usr/src/dahdi-linux-complete-3.4.0+3.4.0}"
ASTERISK_SRC="${ASTERISK_SRC:-/usr/src/asterisk/asterisk-18.21.0-vici}"
ASTERISK_CONF="${ASTERISK_CONF:-/etc/asterisk/asterisk.conf}"
ASTMODDIR="${ASTMODDIR:-/usr/lib64/asterisk/modules}"
JOBS="${JOBS:-$(nproc)}"
ASSUME_YES=0
REBUILD_DAHDI=0

for arg in "$@"; do
    case "$arg" in
        -y|--yes)
            ASSUME_YES=1
            ;;
        --rebuild-dahdi)
            REBUILD_DAHDI=1
            ;;
        -h|--help)
            sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

C_RESET=$'\033[0m'
C_RED=$'\033[1;31m'
C_GREEN=$'\033[1;32m'
C_YELLOW=$'\033[1;33m'
C_BLUE=$'\033[1;34m'

info() { printf "\n%s[INFO]%s %s\n" "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf "\n%s[ OK ]%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "\n%s[WARN]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
die()  { printf "\n%s[FAIL]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || die "Run this script as root."

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/asterisk-dahdi-backup-$TS"
mkdir -p "$BACKUP_DIR"

###############################################################################
# Auto-detect source trees if defaults are absent
###############################################################################

if [[ ! -d "$DAHDI_SRC/linux" ]]; then
    found="$(find /usr/src -maxdepth 2 -type d -name 'dahdi-linux-complete-*' 2>/dev/null | sort -V | tail -n1 || true)"
    [[ -n "$found" ]] || die "DAHDI source tree not found."
    DAHDI_SRC="$found"
fi

if [[ ! -f "$ASTERISK_SRC/configure" ]]; then
    found="$(find /usr/src -maxdepth 3 -type f -path '*/asterisk-18*/configure' 2>/dev/null | sort -V | tail -n1 || true)"
    [[ -n "$found" ]] || die "Asterisk 18 source tree not found."
    ASTERISK_SRC="$(dirname "$found")"
fi

info "DAHDI source    : $DAHDI_SRC"
info "Asterisk source : $ASTERISK_SRC"
info "Module directory: $ASTMODDIR"
info "Backup directory: $BACKUP_DIR"
info "Kernel          : $(uname -r)"

###############################################################################
# Preserve existing configuration/modules
###############################################################################

[[ -f "$ASTERISK_CONF" ]] || die "Missing $ASTERISK_CONF"

cp -a "$ASTERISK_CONF" "$BACKUP_DIR/asterisk.conf"

if [[ -d "$ASTMODDIR" ]]; then
    # Preserve known proprietary/third-party codec modules.
    for m in codec_g729.so codec_g723.so codec_g729b.so; do
        if [[ -f "$ASTMODDIR/$m" ]]; then
            cp -a "$ASTMODDIR/$m" "$BACKUP_DIR/"
            ok "Backed up $m"
        fi
    done
fi

mkdir -p "$ASTMODDIR"

###############################################################################
# DAHDI source compatibility patches
###############################################################################

info "Checking DAHDI source compatibility patches"

KERNEL_H="$DAHDI_SRC/linux/include/dahdi/kernel.h"
XPP="$DAHDI_SRC/linux/drivers/dahdi/xpp/xbus-sysfs.c"
SYSFS="$DAHDI_SRC/linux/drivers/dahdi/dahdi-sysfs.c"
SYSFS_CHAN="$DAHDI_SRC/linux/drivers/dahdi/dahdi-sysfs-chan.c"

for f in "$KERNEL_H" "$XPP" "$SYSFS" "$SYSFS_CHAN"; do
    [[ -f "$f" ]] || die "Missing DAHDI source file: $f"
    if [[ ! -f "${f}.pre-el9-fix" ]]; then
        cp -a "$f" "${f}.pre-el9-fix"
    fi
done

# RHEL/Alma/Rocky 9.8 kernels can expose timer_container_of() while this
# DAHDI version still references from_timer().
if ! grep -q 'DAHDI_EL9_TIMER_COMPAT' "$KERNEL_H"; then
    cat >> "$KERNEL_H" <<'EOF'

/*
 * DAHDI_EL9_TIMER_COMPAT
 * Compatibility for kernels which provide timer_container_of()
 * but older DAHDI code still calls from_timer().
 */
#if !defined(from_timer) && defined(timer_container_of)
#define from_timer timer_container_of
#endif
EOF
    ok "Added DAHDI timer compatibility macro"
else
    ok "DAHDI timer compatibility macro already present"
fi

# Patch ONLY bus .match callbacks. Never globally convert all device_driver
# pointers to const because driver_unregister() still needs a non-const pointer.
python3 - "$DAHDI_SRC" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
items = [
    (root / "linux/drivers/dahdi/xpp/xbus-sysfs.c",
     ["astribank_match", "xpd_match"]),
    (root / "linux/drivers/dahdi/dahdi-sysfs.c",
     ["span_match"]),
    (root / "linux/drivers/dahdi/dahdi-sysfs-chan.c",
     ["chan_match"]),
]

for path, functions in items:
    text = path.read_text()

    for fn in functions:
        pattern = (
            r"(static\s+int\s+" + re.escape(fn) +
            r"\s*\(\s*struct\s+device\s*\*\s*\w+\s*,\s*)"
            r"(?:const\s+)?struct\s+device_driver\s*\*\s*(\w+)"
        )
        repl = r"\1const struct device_driver *\2"
        text, n = re.subn(pattern, repl, text, flags=re.MULTILINE)
        if n:
            print(f"patched {fn}")
        else:
            if re.search(
                r"static\s+int\s+" + re.escape(fn) +
                r"\s*\([^)]*const\s+struct\s+device_driver\s*\*",
                text,
                flags=re.MULTILINE | re.DOTALL
            ):
                print(f"already patched {fn}")
            else:
                print(f"WARNING: {fn} signature not found")

    path.write_text(text)

# Undo the common accidental over-patch only inside xpd_driver_unregister().
path = root / "linux/drivers/dahdi/xpp/xbus-sysfs.c"
text = path.read_text()
m = re.search(
    r"(static\s+void\s+xpd_driver_unregister\s*\([^)]*\)\s*\{)(.*?)(\n\})",
    text,
    flags=re.DOTALL,
)
if m:
    body = m.group(2).replace(
        "const struct device_driver *driver",
        "struct device_driver *driver"
    )
    text = text[:m.start(2)] + body + text[m.end(2):]
    path.write_text(text)
PY

###############################################################################
# Build/install DAHDI only when required
###############################################################################

DAHDI_NEEDS_BUILD=0

if [[ "$REBUILD_DAHDI" -eq 1 ]]; then
    DAHDI_NEEDS_BUILD=1
elif ! modinfo dahdi >/dev/null 2>&1; then
    DAHDI_NEEDS_BUILD=1
elif [[ ! -f /usr/include/dahdi/user.h ]]; then
    DAHDI_NEEDS_BUILD=1
elif [[ ! -f /usr/include/dahdi/tonezone.h ]]; then
    DAHDI_NEEDS_BUILD=1
fi

if [[ "$DAHDI_NEEDS_BUILD" -eq 1 ]]; then
    info "Building/installing DAHDI"
    cd "$DAHDI_SRC"
    make clean
    make -j"$JOBS"
    make install
    make config || true
    depmod -a
    ldconfig
else
    ok "DAHDI kernel module and development headers are already installed"
fi

modprobe dahdi || die "Unable to load the DAHDI kernel module"

###############################################################################
# Validate Asterisk DAHDI dependencies before touching Asterisk
###############################################################################

info "Checking dependencies needed by chan_dahdi"

[[ -f /usr/include/dahdi/user.h ]] \
    || die "/usr/include/dahdi/user.h is missing"

[[ -f /usr/include/dahdi/tonezone.h ]] \
    || die "/usr/include/dahdi/tonezone.h is missing"

if ! ldconfig -p 2>/dev/null | grep -q 'libtonezone'; then
    # Some installations put it outside the current ld.so cache.
    tonezone="$(find /usr/lib /usr/lib64 /usr/local/lib -name 'libtonezone.so*' 2>/dev/null | head -n1 || true)"
    [[ -n "$tonezone" ]] || die "libtonezone was not found. Install DAHDI tools first."
    warn "libtonezone exists at $tonezone but is not in ldconfig cache; running ldconfig"
    ldconfig
fi

ok "DAHDI headers and libtonezone found"

###############################################################################
# Targeted Asterisk configure/build
###############################################################################

info "Preparing targeted Asterisk chan_dahdi build"

cd "$ASTERISK_SRC"

# Back up current generated configuration files from the source tree.
for f in makeopts menuselect.makeopts config.status; do
    [[ -f "$f" ]] && cp -a "$f" "$BACKUP_DIR/source-$f"
done

# We intentionally disable bundled PJPROJECT for this targeted offline build.
# chan_dahdi itself depends on DAHDI, tonezone and res_smdi, not PJPROJECT.
#
# Do not run make install after this. We only copy the modules we explicitly
# build below, so existing PJSIP/G729/VICIdial modules are not replaced.
CONFIG_LOG="$BACKUP_DIR/asterisk-configure.log"

./configure \
    --libdir=/usr/lib64 \
    --without-pjproject-bundled \
    >"$CONFIG_LOG" 2>&1 || {
        tail -n 80 "$CONFIG_LOG"
        die "Asterisk ./configure failed. Full log: $CONFIG_LOG"
    }

ok "Asterisk configure completed without bundled PJPROJECT"

# Confirm configure actually found DAHDI.
HAVE_DAHDI="$(awk -F= '/^HAVE_DAHDI=/{print $2}' makeopts | tail -n1 | tr -d '[:space:]')"
TONEZONE_LIB="$(awk -F= '/^TONEZONE_LIB=/{sub(/^[^=]*=/,""); print}' makeopts | tail -n1)"

echo "HAVE_DAHDI=$HAVE_DAHDI"
echo "TONEZONE_LIB=$TONEZONE_LIB"

[[ "$HAVE_DAHDI" == "1" ]] \
    || die "Asterisk configure did not detect DAHDI. Check $CONFIG_LOG"

[[ -n "$TONEZONE_LIB" ]] \
    || die "Asterisk configure did not detect libtonezone. Check $CONFIG_LOG"

# Create/update menuselect state and explicitly enable dependencies.
make menuselect.makeopts

menuselect/menuselect --enable res_smdi menuselect.makeopts || true
menuselect/menuselect --enable chan_dahdi menuselect.makeopts || true
menuselect/menuselect --enable codec_dahdi menuselect.makeopts || true
menuselect/menuselect --enable res_timing_dahdi menuselect.makeopts || true

# Re-check menuselect dependencies.
menuselect/menuselect --check-deps menuselect.makeopts || true

info "Menuselect DAHDI status"
menuselect/menuselect --list-options menuselect.makeopts 2>/dev/null \
    | grep -E 'chan_dahdi|codec_dahdi|res_timing_dahdi|res_smdi' || true

###############################################################################
# Build WITHOUT installing all Asterisk modules
###############################################################################

info "Building Asterisk modules in the source tree"

# A full source-tree build is used because it reliably resolves generated
# headers and module dependencies. Nothing is installed by this command.
make -j"$JOBS"

BUILT_CHAN="$ASTERISK_SRC/channels/chan_dahdi.so"
BUILT_SMDI="$ASTERISK_SRC/res/res_smdi.so"
BUILT_CODEC="$ASTERISK_SRC/codecs/codec_dahdi.so"
BUILT_TIMING="$ASTERISK_SRC/res/res_timing_dahdi.so"

if [[ ! -f "$BUILT_CHAN" ]]; then
    echo
    echo "Relevant configure information:"
    grep -E '^(HAVE_DAHDI|DAHDI_INCLUDE|TONEZONE_INCLUDE|TONEZONE_LIB|ASTMODDIR|ASTLIBDIR)' \
        makeopts || true
    echo
    echo "Menuselect entry:"
    menuselect/menuselect --list-options menuselect.makeopts 2>/dev/null \
        | grep -i chan_dahdi || true
    die "Build completed but $BUILT_CHAN was not generated."
fi

ok "Built $BUILT_CHAN"

###############################################################################
# Install ONLY DAHDI-related Asterisk modules
###############################################################################

info "Installing only the DAHDI-related Asterisk modules into $ASTMODDIR"

install -m 0755 "$BUILT_CHAN" "$ASTMODDIR/chan_dahdi.so"

if [[ -f "$BUILT_SMDI" ]]; then
    install -m 0755 "$BUILT_SMDI" "$ASTMODDIR/res_smdi.so"
fi

if [[ -f "$BUILT_CODEC" ]]; then
    install -m 0755 "$BUILT_CODEC" "$ASTMODDIR/codec_dahdi.so"
fi

if [[ -f "$BUILT_TIMING" ]]; then
    install -m 0755 "$BUILT_TIMING" "$ASTMODDIR/res_timing_dahdi.so"
fi

ldconfig

# Restore proprietary modules if something outside this script altered them.
for m in codec_g729.so codec_g723.so codec_g729b.so; do
    if [[ -f "$BACKUP_DIR/$m" && ! -f "$ASTMODDIR/$m" ]]; then
        cp -a "$BACKUP_DIR/$m" "$ASTMODDIR/$m"
        warn "Restored $m from backup"
    fi
done

###############################################################################
# Force Asterisk configuration to use existing EL9 /usr/lib64 module path
###############################################################################

python3 - "$ASTERISK_CONF" "$ASTMODDIR" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
moddir = sys.argv[2]
text = path.read_text()

pat = r"(?mi)^[ \t]*astmoddir[ \t]*=>[ \t]*.*$"

if re.search(pat, text):
    text = re.sub(pat, f"astmoddir => {moddir}", text, count=1)
else:
    m = re.search(r"(?mi)^\[directories\][ \t]*$", text)
    if m:
        text = text[:m.end()] + f"\nastmoddir => {moddir}" + text[m.end():]
    else:
        text = f"[directories]\nastmoddir => {moddir}\n\n" + text

path.write_text(text)
PY

ok "asterisk.conf module directory set to $ASTMODDIR"

###############################################################################
# Library check before restart
###############################################################################

info "Checking chan_dahdi.so shared libraries"

missing="$(ldd "$ASTMODDIR/chan_dahdi.so" 2>/dev/null | grep 'not found' || true)"
if [[ -n "$missing" ]]; then
    echo "$missing"
    die "chan_dahdi.so has missing libraries."
fi

ok "chan_dahdi.so has no missing shared libraries"

###############################################################################
# Restart / load
###############################################################################

echo
warn "Asterisk requires a full restart to change astmoddir. Active calls will drop."

if [[ "$ASSUME_YES" -eq 0 ]]; then
    read -r -p "Restart Asterisk now? [y/N]: " answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *)
            echo
            echo "Build/install completed. Restart later with:"
            echo "  systemctl restart asterisk"
            echo "Then verify:"
            echo "  asterisk -rx 'module show like dahdi'"
            exit 0
            ;;
    esac
fi

if systemctl list-unit-files 2>/dev/null | grep -q '^asterisk\.service'; then
    systemctl stop asterisk || true
fi

# On VICIdial servers an older manually-started process can remain.
if pgrep -x asterisk >/dev/null 2>&1; then
    asterisk -rx "core stop now" || true
    sleep 2
fi

if pgrep -x asterisk >/dev/null 2>&1; then
    die "Old Asterisk process is still running. Stop PID(s): $(pgrep -x asterisk | xargs)"
fi

if systemctl list-unit-files 2>/dev/null | grep -q '^asterisk\.service'; then
    systemctl start asterisk
else
    /usr/sbin/asterisk
fi

sleep 2

###############################################################################
# Final verification
###############################################################################

info "Final verification"

echo
echo "Asterisk version:"
asterisk -V || true

echo
echo "Active module directory:"
asterisk -rx "core show settings" 2>/dev/null | grep -i 'Module directory' || true

echo
echo "Installed DAHDI module:"
ls -lh "$ASTMODDIR/chan_dahdi.so"

echo
echo "G729 module:"
if [[ -f "$ASTMODDIR/codec_g729.so" ]]; then
    ls -lh "$ASTMODDIR/codec_g729.so"
else
    echo "codec_g729.so not present in $ASTMODDIR"
fi

echo
echo "Asterisk DAHDI modules:"
asterisk -rx "module show like dahdi" || true

if ! asterisk -rx "module show like dahdi" 2>/dev/null | grep -q 'chan_dahdi.so'; then
    echo
    echo "Attempting manual chan_dahdi load..."
    asterisk -rx "module load res_smdi.so" || true
    asterisk -rx "module load chan_dahdi.so" || true
fi

echo
echo "DAHDI module status after load:"
asterisk -rx "module show like dahdi" || true

echo
echo "DAHDI channels:"
asterisk -rx "dahdi show channels" || true

echo
echo "Linux DAHDI:"
lsmod | grep '^dahdi' || true

echo
echo "Backup:"
echo "$BACKUP_DIR"

echo
echo "=============================================================="
echo "Completed."
echo "Asterisk source : $ASTERISK_SRC"
echo "DAHDI source    : $DAHDI_SRC"
echo "Module dir      : $ASTMODDIR"
echo "chan_dahdi      : $ASTMODDIR/chan_dahdi.so"
echo "=============================================================="
