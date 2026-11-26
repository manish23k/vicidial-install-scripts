#!/usr/bin/env bash
[[ $EUID == 0 ]] || { echo "Run this installer as root." >&2; exit 1; }
set -Ee -o pipefail
export LC_ALL=C
trap 'echo "Installer stopped at line $LINENO (status $?)." >&2' ERR
fail() { echo "Installation error: $*" >&2; exit 1; }
[[ -r /etc/os-release ]] || fail "Missing /etc/os-release"
. /etc/os-release
[[ ${VERSION_ID%%.*} == 10 && ( $ID == almalinux || $ID == rocky ) ]] || fail "This installer requires AlmaLinux or Rocky Linux 10."
case ${PJPROJECT_MODE:-bundled} in bundled|disabled) ;; *) fail "Invalid PJPROJECT_MODE";; esac
resume_relay=0
case "$#:${1:-}" in
    0:) ;;
    1:--resume-ip-relay) resume_relay=1 ;;
    *) fail "Usage: bash $0 [--resume-ip-relay]" ;;
esac
# Stage receipts are local to this host. flock releases the lock on exit.
state=/var/lib/vicidial-installer
install -d -m 700 "$state"
exec 9>"$state/install.lock"
flock -n 9 || fail "Another installer is running."
stage_needed() {
    if [[ -f "$state/$1.done" ]]; then
        echo "[skip] $1"
        return 1
    fi
    echo "[run] $1"
}
finish_stage() {
    date -Is > "$state/$1.tmp"
    mv -f "$state/$1.tmp" "$state/$1.done"
}
if [[ -f "$state/complete.done" ]]; then
    echo "Installation already completed on this server."
    exit 0
fi
if [[ ! -f "$state/database.done" && -d /var/lib/mysql/asterisk && $resume_relay == 0 ]]; then
    if [[ ! -f "$state/settings" &&
          -x /usr/bin/VB-firewall && -s /etc/systemd/system/vicidial-boot.service &&
          -s /etc/astguiclient.conf && -s /etc/httpd/conf.d/viciportal.conf ]]; then
        resume_relay=1
        echo "Detected the earlier installation through the portal stage."
    else
        fail "Existing database has no completed seed receipt. Inspect the previous install before continuing."
    fi
fi
install -d /usr/src /usr/local/bin
work=$(mktemp -d /usr/src/vicidial-setup-XXXXXXXX)
trap 'rm -rf -- "$work"' EXIT
assets=/usr/src/vicidial-install-scripts
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_url=https://raw.githubusercontent.com/carpenox/vicidial-install-scripts/e3373b9b035d3b7534af2fc1eeb3d713b4b15c22
install -d "$assets"
if [[ -s "$state/settings" ]]; then source "$state/settings"; fi
asset_files=(cpanfile extensions.conf confbridge-vicidial.conf)
if [[ ${PJPROJECT_MODE:-bundled} == bundled ]]; then
    asset_files+=(DOMAINNAME.conf asterisk-http.conf asterisk-sip.conf)
fi
for asset in "${asset_files[@]}"; do
    if [[ -s "$assets/$asset" ]]; then continue; fi
    if [[ -s "$script_dir/$asset" ]]; then
        install -m 644 "$script_dir/$asset" "$assets/$asset"
    else
        curl -fLsS --retry 3 "$source_url/$asset" -o "$work/$asset" || fail "Place the missing $asset in $assets"
        install -m 644 "$work/$asset" "$assets/$asset"
    fi
done
usable_cert_name() {
    local name=${1,,}
    [[ ${#name} -le 253 && $name =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || return 1
    case "$name" in
        *.local|*.localhost|*.internal|*.invalid|*.test|*.example|home.arpa|*.home.arpa) return 1 ;;
    esac
}
choose_web_domain() {
    local default=$1 choice
    usable_cert_name "$default" || default=skip
    while true; do
        read -r -p "Public DNS name for webphone TLS, or skip [$default]: " choice ||
            fail "Run interactively to select a public DNS name or skip."
        choice=${choice:-$default}
        if [[ ${choice,,} == skip ]]; then
            web_domain=""
            return
        fi
        if usable_cert_name "$choice"; then
            web_domain=${choice,,}
            return
        fi
        echo "Use a public DNS name you control, or enter skip for a LAN-only installation." >&2
    done
}
if [[ ! -s "$state/settings" ]]; then
default_hostname=$(hostname)
read -r -p "Server hostname [$default_hostname]: " hostname
hostname=${hostname:-$default_hostname}
[[ $hostname =~ ^[[:alnum:]]([[:alnum:].-]*[[:alnum:]])?$ ]] || fail "Invalid hostname"
detected=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}' || true)
read -r -p "Server IPv4 address [$detected]: " ip_address
ip_address=${ip_address:-$detected}
python3 -c 'import ipaddress, sys; ipaddress.IPv4Address(sys.argv[1])' "$ip_address"
web_domain=""
if [[ ${PJPROJECT_MODE:-bundled} == bundled ]]; then
    choose_web_domain "$hostname"
fi
fi
if (( ! resume_relay )); then
if stage_needed system; then
hostnamectl set-hostname "$hostname"

dnf install -y dnf-plugins-core
dnf config-manager --set-enabled crb
dnf install -y epel-release
dnf install -y https://rpms.remirepo.net/enterprise/remi-release-10.rpm
dnf -y module switch-to php:remi-8.4/common
dnf -y group install "Development Tools"
dnf install -y httpd mod_ssl php php-fpm php-cli php-devel php-gd php-mysqlnd php-ldap php-zip \
    php-opcache php-mbstring php-odbc php-pear php-xml mariadb mariadb-server \
    screen subversion git wget tar unzip patch newt-devel libxml2-devel sqlite-devel libuuid-devel \
    libedit-devel ncurses-devel openssl-devel elfutils-libelf-devel libsrtp-devel zlib-devel \
    sox python3-pip firewalld cronie perl-core perl-devel perl-CPAN perl-DBI perl-DBD-MySQL \
    perl-GD perl-Env perl-libwww-perl perl-Term-ReadLine-Gnu perl-YAML perl-File-Which \
    cockpit cockpit-storaged certbot kmod policycoreutils-python-utils
# Install ancillary utilities separately so one unavailable package cannot cancel core dependencies.
for package in php-pecl-mcrypt php-pecl-imap php-pecl-xmlrpc php-curl php-fileinfo \
    gd-devel readline-devel mariadb-devel speex-devel libss7-devel libX11-devel libXext-devel \
    libXft-devel libXpm-devel libXrender-devel libjpeg-devel libpng-devel freetype-devel \
    pv ImageMagick htop iftop atop mytop bind-utils nano sngrep cockpit-navigator \
    cockpit-networkmanager cockpit-packagekit postfix dovecot s-nail roundcubemail inxi; do
    dnf -y install "$package" || echo "Optional package unavailable: $package" >&2
done

# sngrep: SIP signalling viewer
if ! command -v sngrep >/dev/null 2>&1 && [[ ! -x /usr/local/bin/sngrep ]]; then
    (
        build_dir=$(mktemp -d) || exit 1
        trap 'rm -rf -- "$build_dir"' EXIT
        cd "$build_dir" || exit 1

        dnf install -y gcc make autoconf automake pkgconf-pkg-config \
            libpcap-devel ncurses-devel &&
        curl -fLsS --retry 3 \
            https://github.com/irontec/sngrep/releases/download/v1.8.4/sngrep-1.8.4.tar.gz \
            -o sngrep.tar.gz &&
        echo '0f5cc5a356edc1327f1b916fedd9eb0fd1472eda360a04dfe59cabe15a346ee1  sngrep.tar.gz' | sha256sum -c - &&
        tar -xzf sngrep.tar.gz &&
        cd sngrep-1.8.4 &&
        sh ./bootstrap.sh &&
        test -x ./configure &&
        ./configure --prefix=/usr/local &&
        make -j"$(nproc)" &&
        make install &&
        /usr/local/bin/sngrep -V
    ) || echo "Optional tool sngrep could not be installed." >&2
fi

# inxi: system information
if ! command -v inxi >/dev/null 2>&1 && [[ ! -x /usr/local/bin/inxi ]]; then
    (
        download=$(mktemp) || exit 1
        trap 'rm -f -- "$download"' EXIT

        curl -fLsS --retry 3 \
            https://codeberg.org/smxi/inxi/raw/master/inxi \
            -o "$download" &&
        perl -c "$download" &&
        install -D -m 0755 "$download" /usr/local/bin/inxi
    ) || echo "Optional tool inxi could not be installed." >&2
fi

python3 -m pip install mysql-connector-python
systemctl enable --now firewalld cockpit.socket
install -d /etc/php.d /etc/my.cnf.d /etc/httpd/conf.d
cat > /etc/php.d/99-vicidial.ini <<'EOF'
error_reporting  =  E_ALL & ~E_NOTICE
memory_limit = 448M
short_open_tag = On
max_execution_time = 3330
max_input_time = 3360
post_max_size = 448M
upload_max_filesize = 442M
default_socket_timeout = 3360
date.timezone = America/New_York
max_input_vars = 50000
EOF
cat > /etc/my.cnf.d/90-vicidial.cnf <<'MYSQLCONF'
[client]
port = 3306
socket = /var/lib/mysql/mysql.sock

[mysqld]
datadir = /var/lib/mysql
#tmpdir = /home/mysql_tmp
socket = /var/lib/mysql/mysql.sock
user = mysql
ft_min_word_len = 3
max_connections = 800
max_allowed_packet = 32M
skip-external-locking
sql_mode="NO_ENGINE_SUBSTITUTION"

log-error = /var/log/mysqld/mysqld.log

query-cache-type = 1
query-cache-size = 32M

long_query_time = 1
#slow_query_log = 1
#slow_query_log_file = /var/log/mysqld/slow-queries.log

tmp_table_size = 128M
table_open_cache = 1024
join_buffer_size = 1M
key_buffer = 512M
sort_buffer_size = 6M
read_buffer_size = 4M
read_rnd_buffer_size = 16M
myisam_sort_buffer_size = 64M

thread_cache_size = 8
[mysqldump]
quick
max_allowed_packet = 16M

[mysql]
no-auto-rehash

MYSQLCONF
install -d -o mysql -g mysql -m 750 /var/log/mysqld
systemctl enable mariadb php-fpm httpd
systemctl restart mariadb php-fpm httpd
    finish_stage system
fi
fi
# Use the same root authentication for every SQL invocation.
db=(mariadb --user=root)
if ! "${db[@]}" -e "SELECT 1" >/dev/null 2>&1; then
    read -rs -p "MariaDB root password: " db_password
    echo
    # The client reads this escaped value from a private, temporary option file.
    escaped=${db_password//\\/\\\\}
    escaped=${escaped//\"/\\\"}
    printf '[client]\npassword="%s"\n' "$escaped" > "$work/db.cnf"
    unset escaped
    chmod 600 "$work/db.cnf"
    unset db_password
    db=(mariadb --defaults-extra-file="$work/db.cnf" --user=root)
fi
if (( resume_relay )); then
    relay_zip=/usr/src/astguiclient/trunk/extras/ip_relay/ip_relay_1.1.112705.zip
    [[ -s "$relay_zip" && -s /etc/astguiclient.conf && -s /etc/systemd/system/vicidial-boot.service ]] ||
        fail "Resume requires the existing VICIdial installation through the ip_relay stage."
    server_rows=$("${db[@]}" asterisk -Nse "SELECT COUNT(*) FROM servers WHERE server_ip='$ip_address'")
    [[ "$server_rows" == 1 ]] || fail "Use the IPv4 address of the previously installed VICIdial server."
    for required in /usr/sbin/asterisk /usr/lib64/asterisk/modules/chan_dahdi.so \
        /usr/local/sbin/vicidial-boot /var/www/html/CyburPhone/cyburphone.php \
        /etc/httpd/conf.d/viciportal.conf /usr/bin/VB-firewall /usr/bin/aggregate; do
        [[ -s "$required" ]] || fail "Earlier installation is missing $required."
    done
    relay_bin=/usr/src/astguiclient/trunk/extras/ip_relay/ip_relay_1.1/src/unix/ip_relay
    if [[ -x "$relay_bin" && -x /usr/bin/ip_relay && -x /usr/local/bin/ip_relay ]] &&
       cmp -s "$relay_bin" /usr/bin/ip_relay && cmp -s "$relay_bin" /usr/local/bin/ip_relay; then
        finish_stage ip-relay
    fi
    if [[ -s /etc/cron.d/vicidial ]] && grep -Fq 'ADMIN_keepalive_ALL.pl' /etc/cron.d/vicidial &&
       [[ -f "$state/ip-relay.done" ]] && systemctl is-enabled --quiet vicidial-boot.service &&
       systemctl is-active --quiet crond &&
       asterisk -rx 'module show like chan_dahdi.so' | grep -E 'chan_dahdi\.so.*Running' >/dev/null; then
        finish_stage complete
        echo "Existing completed installation verified."
        exit 0
    fi
    for installed in system perl telephony database vicidial boot webphone portal; do
        finish_stage "$installed"
    done
fi
save_settings() {
    {
        printf 'hostname=%q\nip_address=%q\nweb_domain=%q\n' "$hostname" "$ip_address" "$web_domain"
        printf 'PJPROJECT_MODE=%q\nDAHDI_SKIP_VPMADT032=%q\n' "${PJPROJECT_MODE:-bundled}" "${DAHDI_SKIP_VPMADT032:-1}"
    } > "$state/settings.tmp"
    mv "$state/settings.tmp" "$state/settings"
}
if [[ ! -s "$state/settings" ]]; then save_settings; fi
if stage_needed perl; then
# Install native Tk modules from EL10 packages before resolving the cpanfile.
dnf -y install perl-Tk perl-Tk-TableMatrix
perl -MTk -MTk::TableMatrix -e 1

# String::CRC 1.0 passes an int pointer to SvPV(), which expects STRLEN *.
# Keep the same CRC implementation and use Perl's length type throughout.
if ! perl -MString::CRC=1.0 -e 1 >/dev/null 2>&1; then
    (
        cd "$work"
        curl -fLsS --retry 3 https://cpan.metacpan.org/authors/id/M/MU/MUIR/modules/String-CRC-1.0.tar.gz -o String-CRC-1.0.tar.gz
        echo '847d2664ef0ed251efc9a67b7670577b607b2600ba83465b642cf6a598a1236c  String-CRC-1.0.tar.gz' | sha256sum -c -
        tar -xzf String-CRC-1.0.tar.gz
        cd String-CRC-1.0
        sed -i -e 's/int data_len;/STRLEN data_len;/' \
            -e 's/crc_calculate(char \*p, int len)/crc_calculate(char *p, STRLEN len)/' CRC.xs
        perl Makefile.PL
        make
        make test
        make install
    )
fi
perl -MString::CRC=1.0 -e 1
cd "$assets"
curl -fsSL --retry 3 https://raw.githubusercontent.com/skaji/cpm/main/cpm -o "$work/cpm"
perl "$work/cpm" install -g --show-build-log-on-failure
#Install Asterisk Perl
cd "$work"
wget -O asterisk-perl-0.08.tar.gz https://download.vicidial.com/required-apps/asterisk-perl-0.08.tar.gz
tar xzf asterisk-perl-0.08.tar.gz
cd asterisk-perl-0.08
perl Makefile.PL
make all
make install 




# Use the distribution codec and JSON libraries for the CLI and Asterisk.
dnf install -y lame jansson-devel
    finish_stage perl
fi
if stage_needed telephony; then

(
set -eu -o pipefail
die() { echo "Telephony installation failed: $*" >&2; exit 1; }
ok() { echo "$*"; }
DAHDI_SRC=/usr/src/dahdi-linux-complete-3.4.0+3.4.0
ASTERISK_SRC=/usr/src/asterisk/asterisk-18.21.0-vici
ASTMODDIR=/usr/lib64/asterisk/modules
JOBS=${JOBS:-$(nproc)}
backup=$(mktemp -d /root/asterisk-dahdi-backup-XXXXXXXX)
echo "Telephony backup directory: $backup"
for file in /etc/asterisk/asterisk.conf "$ASTMODDIR"/{codec_g729,codec_g723,codec_g729b}.so; do
    if [[ -f "$file" ]]; then cp -a "$file" "$backup/"; fi
done

# Extract into a temporary directory first so interrupted downloads can be retried.
stage=$(mktemp -d /usr/src/telephony-build-XXXXXXXX)
trap 'rm -rf -- "$stage"' EXIT
if stage_needed "dahdi-$(uname -r)"; then
if [[ ! -f "$DAHDI_SRC/linux/include/dahdi/kernel.h" ]]; then
    wget -O "$stage/dahdi.zip" https://cybur-dial.com/downloads/dahdi-alma10.zip
    unzip -q "$stage/dahdi.zip" -d "$stage/dahdi"
    header=$(find "$stage/dahdi" -path '*/linux/include/dahdi/kernel.h' -print -quit)
    [[ -n "$header" ]] || die "Cannot locate DAHDI source in downloaded archive"
    mkdir -p "$DAHDI_SRC"
    cp -a "${header%/linux/include/dahdi/kernel.h}/." "$DAHDI_SRC/"
fi

kernel_build=/lib/modules/$(uname -r)/build
if [[ ! -f "$kernel_build/Makefile" ]]; then
    dnf install -y "kernel-devel-$(uname -r)"
fi
[[ -f "$kernel_build/Makefile" ]] || die "Missing build tree for the running kernel $(uname -r)"
dnf install -y newt-devel libuuid-devel libxml2-devel
if [[ -f /usr/lib/modules/$(uname -r)/vmlinux.xz && ! -e /boot/vmlinux.xz ]]; then
    ln -sf "/usr/lib/modules/$(uname -r)/vmlinux.xz" /boot/vmlinux.xz
fi

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


cd "$DAHDI_SRC"
export DAHDI_SKIP_VPMADT032="${DAHDI_SKIP_VPMADT032:-1}"
if [[ "$DAHDI_SKIP_VPMADT032" == 1 ]]; then
    kbuild=linux/drivers/dahdi/Kbuild
    if ! grep -Fxq 'ifeq ($(DAHDI_SKIP_VPMADT032),1)' "$kbuild"; then
        [[ -e "$kbuild.before-vpmadt032-fix" ]] || cp -p "$kbuild" "$kbuild.before-vpmadt032-fix"
        cat >> "$kbuild" <<'KBUILD'

ifeq ($(DAHDI_SKIP_VPMADT032),1)
obj-m := $(filter-out dahdi_vpmadt032_loader.o,$(obj-m))
endif
KBUILD
    fi
fi
# The Alma10 archive contains generated files from the packaging host.
(cd tools && autoreconf -fi && ./configure --prefix=/usr --libdir=/usr/lib64 --sysconfdir=/etc --with-dahdi=../linux)
make clean
make -j"$JOBS"
make install
make -C tools install-config
depmod -a
ldconfig
[[ -f /usr/include/dahdi/user.h && -f /usr/include/dahdi/tonezone.h ]] || die "Missing installed DAHDI headers"
if ! ldconfig -p | grep 'libtonezone\.so' >/dev/null ||
   [[ ! -e /usr/lib64/libtonezone.so && ! -e /usr/lib/libtonezone.so && ! -e /usr/local/lib/libtonezone.so && ! -e /usr/local/lib64/libtonezone.so ]]; then
    lib=tools/.libs/libtonezone.so.2.0.0
    [[ -f "$lib" ]] || die "DAHDI tools did not install libtonezone"
    install -m 755 "$lib" /usr/lib64/
    ln -sfn libtonezone.so.2.0.0 /usr/lib64/libtonezone.so.2
    ln -sfn libtonezone.so.2 /usr/lib64/libtonezone.so
    ldconfig
fi
if [[ ! -f /etc/dahdi/system.conf && -f /etc/dahdi/system.conf.sample ]]; then
    cp /etc/dahdi/system.conf.sample /etc/dahdi/system.conf
fi
modprobe dahdi
if modinfo dahdi_dummy >/dev/null 2>&1; then modprobe dahdi_dummy; fi
dahdi_cfg -vv
if systemctl cat dahdi.service >/dev/null 2>&1 || [[ -x /etc/init.d/dahdi ]]; then
    systemctl daemon-reload
    systemctl enable --now dahdi
fi

finish_stage "dahdi-$(uname -r)"
fi

mkdir -p /usr/src/asterisk
cd /usr/src/asterisk
if [[ ! -f libpri-1.6.1/Makefile ]]; then
    wget -O "$stage/libpri.tgz" https://downloads.asterisk.org/pub/telephony/libpri/libpri-1.6.1.tar.gz
    tar -xzf "$stage/libpri.tgz"
fi
make -C libpri-1.6.1
make -C libpri-1.6.1 install
if [[ ! -f "$ASTERISK_SRC/configure" ]]; then
    wget -O "$stage/asterisk.tgz" https://download.vicidial.com/required-apps/asterisk-18.21.0-vici.tar.gz
    tar -xzf "$stage/asterisk.tgz"
fi
ldconfig

cd "$ASTERISK_SRC"
for f in makeopts menuselect.makeopts build_tools/menuselect-deps config.log config.status include/asterisk/autoconfig.h; do
    if [[ -f "$f" ]]; then cp -a --parents "$f" "$backup/"; fi
done
case "${PJPROJECT_MODE:-bundled}" in
    bundled) pj_flags=(--with-pjproject-bundled) ;;
    disabled) pj_flags=(--without-pjproject-bundled --without-pjproject) ;;
    *) die "PJPROJECT_MODE must be bundled or disabled" ;;
esac
./configure --libdir=/usr/lib64 --with-gsm=internal --with-srtp --with-ssl --enable-asteriskssl "${pj_flags[@]}" --without-jansson-bundled
MENUSELECT_DEPS=build_tools/menuselect-deps
python3 - "$MENUSELECT_DEPS" <<'PY'
import re
import sys
from pathlib import Path

p = Path(sys.argv[1])
lines = []

for raw in p.read_text().splitlines():
    # Preserve ordinary/unrecognized lines exactly.
    m = re.match(r'^([^=]+)=(-?\d+)(?::(-?\d+))?$', raw.strip())
    if not m:
        lines.append(raw)
        continue

    name, current, previous = m.groups()

    # Asterisk menuselect accepts NAME=current:previous.
    # Set previous=current to acknowledge the intentional dependency state.
    lines.append(f"{name}={current}:{current}")

p.write_text("\n".join(lines) + "\n")
PY


rm -f menuselect.makeopts menuselect.makedeps
make clean
make menuselect/menuselect menuselect-tree
make menuselect.makeopts
required=(channels/chan_sip res/res_rtp_asterisk res/res_smdi channels/chan_dahdi
          codecs/codec_dahdi res/res_timing_dahdi apps/app_meetme res/res_http_websocket res/res_srtp)
if [[ ${PJPROJECT_MODE:-bundled} == bundled ]]; then
    required+=(channels/chan_pjsip res/res_pjsip)
fi
for mod in "${required[@]}"; do
    menuselect/menuselect --enable "${mod##*/}" menuselect.makeopts
done
menuselect/menuselect --check-deps menuselect.makeopts
make -j"$JOBS" all
for mod in "${required[@]}"; do
    [[ -s "$mod.so" ]] || die "Required module $mod.so was not built. Check configure and menuselect."
done
make install
make samples
for mod in codec_g729.so codec_g723.so codec_g729b.so; do
    if [[ -f "$backup/$mod" ]]; then cp -a "$backup/$mod" "$ASTMODDIR/$mod"; fi
done
ldconfig
libs=$(ldd "$ASTMODDIR/chan_dahdi.so")
if [[ "$libs" == *"not found"* ]]; then die "Unresolved chan_dahdi dependencies: $libs"; fi
)
    finish_stage telephony
fi
if stage_needed database; then
existing=$("${db[@]}" -Nse "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='asterisk'")
[[ "$existing" == 0 ]] || fail "The asterisk database already exists. This full installer seeds a new database."
#Install astguiclient
echo "Installing astguiclient"
mkdir -p /usr/src/astguiclient
cd /usr/src/astguiclient
svn checkout svn://svn.eflo.net/agc_2-X/trunk
cd /usr/src/astguiclient/trunk

for seed in MySQL_AST_CREATE_tables.sql first_server_install.sql; do
    [[ -s "extras/$seed" ]] || fail "Missing VICIdial SQL file: extras/$seed"
done
# Add database accounts and seed the freshly created database.
"${db[@]}" <<MYSQLCREOF
CREATE DATABASE asterisk DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;
CREATE USER 'cron'@'localhost' IDENTIFIED BY '1234';
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES on asterisk.* TO cron@'%' IDENTIFIED BY '1234';
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES on asterisk.* TO cron@localhost IDENTIFIED BY '1234';
GRANT RELOAD ON *.* TO cron@'%';
GRANT RELOAD ON *.* TO cron@localhost;
CREATE USER 'custom'@'localhost' IDENTIFIED BY 'custom1234';
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES on asterisk.* TO custom@'%' IDENTIFIED BY 'custom1234';
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES on asterisk.* TO custom@localhost IDENTIFIED BY 'custom1234';
GRANT RELOAD ON *.* TO custom@'%';
GRANT RELOAD ON *.* TO custom@localhost;
flush privileges;

SET GLOBAL connect_timeout=60;

use asterisk;
\. /usr/src/astguiclient/trunk/extras/MySQL_AST_CREATE_tables.sql
\. /usr/src/astguiclient/trunk/extras/first_server_install.sql
update servers set asterisk_version='18.21.0-vici';
MYSQLCREOF
    finish_stage database
fi
if stage_needed vicidial; then
cd /usr/src/astguiclient/trunk
#Get astguiclient.conf file
cat <<ASTGUI > /etc/astguiclient.conf
# astguiclient.conf - configuration elements for the astguiclient package
# this is the astguiclient configuration file
# all comments will be lost if you run install.pl again

# Paths used by astGUIclient
PATHhome => /usr/share/astguiclient
PATHlogs => /var/log/astguiclient
PATHagi => /var/lib/asterisk/agi-bin
PATHweb => /var/www/html
PATHsounds => /var/lib/asterisk/sounds
PATHmonitor => /var/spool/asterisk/monitor
PATHDONEmonitor => /var/spool/asterisk/monitorDONE

# The IP address of this machine
VARserver_ip => SERVERIP

# Database connection information
VARDB_server => localhost
VARDB_database => asterisk
VARDB_user => cron
VARDB_pass => 1234
VARDB_custom_user => custom
VARDB_custom_pass => custom1234
VARDB_port => 3306

# Alpha-Numeric list of the astGUIclient processes to be kept running
# (value should be listing of characters with no spaces: 123456)
#  X - NO KEEPALIVE PROCESSES (use only if you want none to be keepalive)
#  1 - AST_update
#  2 - AST_send_listen
#  3 - AST_VDauto_dial
#  4 - AST_VDremote_agents
#  5 - AST_VDadapt (If multi-server system, this must only be on one server)
#  6 - FastAGI_log
#  7 - AST_VDauto_dial_FILL (only for multi-server, this must only be on one server)
#  8 - ip_relay (used for blind agent monitoring)
#  9 - Timeclock auto logout
#  E - Email processor, (If multi-server system, this must only be on one server)
#  S - SIP Logger (Patched Asterisk 13 required)
VARactive_keepalives => 12345689C

# Asterisk version VICIDIAL is installed for
VARasterisk_version => 18.X

# FTP recording archive connection information
VARFTP_host => 10.0.0.4
VARFTP_user => cron
VARFTP_pass => test
VARFTP_port => 21
VARFTP_dir => RECORDINGS
VARHTTP_path => http://10.0.0.4

# REPORT server connection information
VARREPORT_host => 10.0.0.4
VARREPORT_user => cron
VARREPORT_pass => test
VARREPORT_port => 21
VARREPORT_dir => REPORTS

# Settings for FastAGI logging server
VARfastagi_log_min_servers => 3
VARfastagi_log_max_servers => 16
VARfastagi_log_min_spare_servers => 2
VARfastagi_log_max_spare_servers => 8
VARfastagi_log_max_requests => 1000
VARfastagi_log_checkfordead => 30
VARfastagi_log_checkforwait => 60

# Expected DB Schema version for this install
ExpectedDBSchema => 1720
ASTGUI

echo "Replace IP address in Default"
#echo "%%%%%%%%%Please Enter This Server IP ADD%%%%%%%%%%%%"
#read serveripadd
sed -i s/SERVERIP/"$ip_address"/g /etc/astguiclient.conf

echo "Install VICIDIAL"
perl install.pl --no-prompt --copy_sample_conf_files=Y

# VICIdial copies fresh sample files. Apply the final runtime settings now.
python3 - <<'PY'
import re
from pathlib import Path

path = Path("/etc/asterisk/asterisk.conf")
lines = path.read_text().splitlines(keepends=True)
start = next((i for i, line in enumerate(lines)
              if re.match(r"^\s*\[directories\]", line, re.I)), None)
if start is None:
    lines[:0] = ["[directories]\n", "astmoddir => /usr/lib64/asterisk/modules\n"]
else:
    end = next((i for i in range(start + 1, len(lines))
                if re.match(r"^\s*\[", lines[i])), len(lines))
    lines[start:end] = [lines[start].rstrip("\n") + "\n", "astmoddir => /usr/lib64/asterisk/modules\n",
                        *(line for line in lines[start+1:end] if not re.match(r"^\s*astmoddir\s*=", line, re.I))]
path.write_text("".join(lines))
PY
sed -Ei '/^[[:space:]]*noload[[:space:]]*=>?[[:space:]]*chan_sip\.so([[:space:];]|$)/s/^/;/' /etc/asterisk/modules.conf || exit 1

#Secure Manager 
sed -Ei 's/^(\s*bindaddr\s*=\s*)0\.0\.0\.0([[:space:];]|$)/\1127.0.0.1\2/' /etc/asterisk/manager.conf

for module in res_timing_timerfd res_timing_kqueue res_timing_pthread; do
    echo "noload => $module.so"
done >> /etc/asterisk/modules.conf
#Add confbridge conferences to asterisk DB
if stage_needed conferences; then
"${db[@]}" -e "use asterisk; INSERT INTO vicidial_confbridges VALUES (9600000,'10.10.10.15','','0',NULL),(9600001,'10.10.10.15','','0',NULL),(9600002,'10.10.10.15','','0',NULL),(9600003,'10.10.10.15','','0',NULL),(9600004,'10.10.10.15','','0',NULL),(9600005,'10.10.10.15','','0',NULL),(9600006,'10.10.10.15','','0',NULL),(9600007,'10.10.10.15','','0',NULL),(9600008,'10.10.10.15','','0',NULL),(9600009,'10.10.10.15','','0',NULL),(9600010,'10.10.10.15','','0',NULL),(9600011,'10.10.10.15','','0',NULL),(9600012,'10.10.10.15','','0',NULL),(9600013,'10.10.10.15','','0',NULL),(9600014,'10.10.10.15','','0',NULL),(9600015,'10.10.10.15','','0',NULL),(9600016,'10.10.10.15','','0',NULL),(9600017,'10.10.10.15','','0',NULL),(9600018,'10.10.10.15','','0',NULL),(9600019,'10.10.10.15','','0',NULL),(9600020,'10.10.10.15','','0',NULL),(9600021,'10.10.10.15','','0',NULL),(9600022,'10.10.10.15','','0',NULL),(9600023,'10.10.10.15','','0',NULL),(9600024,'10.10.10.15','','0',NULL),(9600025,'10.10.10.15','','0',NULL),(9600026,'10.10.10.15','','0',NULL),(9600027,'10.10.10.15','','0',NULL),(9600028,'10.10.10.15','','0',NULL),(9600029,'10.10.10.15','','0',NULL),(9600030,'10.10.10.15','','0',NULL),(9600031,'10.10.10.15','','0',NULL),(9600032,'10.10.10.15','','0',NULL),(9600033,'10.10.10.15','','0',NULL),(9600034,'10.10.10.15','','0',NULL),(9600035,'10.10.10.15','','0',NULL),(9600036,'10.10.10.15','','0',NULL),(9600037,'10.10.10.15','','0',NULL),(9600038,'10.10.10.15','','0',NULL),(9600039,'10.10.10.15','','0',NULL),(9600040,'10.10.10.15','','0',NULL),(9600041,'10.10.10.15','','0',NULL),(9600042,'10.10.10.15','','0',NULL),(9600043,'10.10.10.15','','0',NULL),(9600044,'10.10.10.15','','0',NULL),(9600045,'10.10.10.15','','0',NULL),(9600046,'10.10.10.15','','0',NULL),(9600047,'10.10.10.15','','0',NULL),(9600048,'10.10.10.15','','0',NULL),(9600049,'10.10.10.15','','0',NULL),(9600050,'10.10.10.15','','0',NULL),(9600051,'10.10.10.15','','0',NULL),(9600052,'10.10.10.15','','0',NULL),(9600053,'10.10.10.15','','0',NULL),(9600054,'10.10.10.15','','0',NULL),(9600055,'10.10.10.15','','0',NULL),(9600056,'10.10.10.15','','0',NULL),(9600057,'10.10.10.15','','0',NULL),(9600058,'10.10.10.15','','0',NULL),(9600059,'10.10.10.15','','0',NULL),(9600060,'10.10.10.15','','0',NULL),(9600061,'10.10.10.15','','0',NULL),
(9600062,'10.10.10.15','','0',NULL),(9600063,'10.10.10.15','','0',NULL),(9600064,'10.10.10.15','','0',NULL),(9600065,'10.10.10.15','','0',NULL),(9600066,'10.10.10.15','','0',NULL),(9600067,'10.10.10.15','','0',NULL),(9600068,'10.10.10.15','','0',NULL),(9600069,'10.10.10.15','','0',NULL),(9600070,'10.10.10.15','','0',NULL),(9600071,'10.10.10.15','','0',NULL),(9600072,'10.10.10.15','','0',NULL),(9600073,'10.10.10.15','','0',NULL),(9600074,'10.10.10.15','','0',NULL),(9600075,'10.10.10.15','','0',NULL),(9600076,'10.10.10.15','','0',NULL),(9600077,'10.10.10.15','','0',NULL),(9600078,'10.10.10.15','','0',NULL),(9600079,'10.10.10.15','','0',NULL),(9600080,'10.10.10.15','','0',NULL),(9600081,'10.10.10.15','','0',NULL),(9600082,'10.10.10.15','','0',NULL),(9600083,'10.10.10.15','','0',NULL),(9600084,'10.10.10.15','','0',NULL),(9600085,'10.10.10.15','','0',NULL),(9600086,'10.10.10.15','','0',NULL),(9600087,'10.10.10.15','','0',NULL),(9600088,'10.10.10.15','','0',NULL),(9600089,'10.10.10.15','','0',NULL),(9600090,'10.10.10.15','','0',NULL),(9600091,'10.10.10.15','','0',NULL),(9600092,'10.10.10.15','','0',NULL),(9600093,'10.10.10.15','','0',NULL),(9600094,'10.10.10.15','','0',NULL),(9600095,'10.10.10.15','','0',NULL),(9600096,'10.10.10.15','','0',NULL),(9600097,'10.10.10.15','','0',NULL),(9600098,'10.10.10.15','','0',NULL),(9600099,'10.10.10.15','','0',NULL),(9600100,'10.10.10.15','','0',NULL),(9600101,'10.10.10.15','','0',NULL),(9600102,'10.10.10.15','','0',NULL),(9600103,'10.10.10.15','','0',NULL),(9600104,'10.10.10.15','','0',NULL),(9600105,'10.10.10.15','','0',NULL),(9600106,'10.10.10.15','','0',NULL),(9600107,'10.10.10.15','','0',NULL),(9600108,'10.10.10.15','','0',NULL),(9600109,'10.10.10.15','','0',NULL),(9600110,'10.10.10.15','','0',NULL),(9600111,'10.10.10.15','','0',NULL),(9600112,'10.10.10.15','','0',NULL),(9600113,'10.10.10.15','','0',NULL),(9600114,'10.10.10.15','','0',NULL),(9600115,'10.10.10.15','','0',NULL),(9600116,'10.10.10.15','','0',NULL),(9600117,'10.10.10.15','','0',NULL),(9600118,'10.10.10.15','','0',NULL),(9600119,'10.10.10.15','','0',NULL),(9600120,'10.10.10.15','','0',NULL),(9600121,'10.10.10.15','','0',NULL),(9600122,'10.10.10.15','','0',NULL),(9600123,'10.10.10.15','','0',NULL),(9600124,'10.10.10.15','','0',NULL),(9600125,'10.10.10.15','','0',NULL),(9600126,'10.10.10.15','','0',NULL),(9600127,'10.10.10.15','','0',NULL),(9600128,'10.10.10.15','','0',NULL),(9600129,'10.10.10.15','','0',NULL),(9600130,'10.10.10.15','','0',NULL),(9600131,'10.10.10.15','','0',NULL),(9600132,'10.10.10.15','','0',NULL),(9600133,'10.10.10.15','','0',NULL),(9600134,'10.10.10.15','','0',NULL),(9600135,'10.10.10.15','','0',NULL),(9600136,'10.10.10.15','','0',NULL),(9600137,'10.10.10.15','','0',NULL),(9600138,'10.10.10.15','','0',NULL),(9600139,'10.10.10.15','','0',NULL),(9600140,'10.10.10.15','','0',NULL),(9600141,'10.10.10.15','','0',NULL),(9600142,'10.10.10.15','','0',NULL),(9600143,'10.10.10.15','','0',NULL),(9600144,'10.10.10.15','','0',NULL),(9600145,'10.10.10.15','','0',NULL),(9600146,'10.10.10.15','','0',NULL),(9600147,'10.10.10.15','','0',NULL),(9600148,'10.10.10.15','','0',NULL),(9600149,'10.10.10.15','','0',NULL),(9600150,'10.10.10.15','','0',NULL),(9600151,'10.10.10.15','','0',NULL),(9600152,'10.10.10.15','','0',NULL),(9600153,'10.10.10.15','','0',NULL),(9600154,'10.10.10.15','','0',NULL),(9600155,'10.10.10.15','','0',NULL),(9600156,'10.10.10.15','','0',NULL),(9600157,'10.10.10.15','','0',NULL),(9600158,'10.10.10.15','','0',NULL),(9600159,'10.10.10.15','','0',NULL),(9600160,'10.10.10.15','','0',NULL),(9600161,'10.10.10.15','','0',NULL),(9600162,'10.10.10.15','','0',NULL),(9600163,'10.10.10.15','','0',NULL),(9600164,'10.10.10.15','','0',NULL),(9600165,'10.10.10.15','','0',NULL),(9600166,'10.10.10.15','','0',NULL),(9600167,'10.10.10.15','','0',NULL),(9600168,'10.10.10.15','','0',NULL),(9600169,'10.10.10.15','','0',NULL),(9600170,'10.10.10.15','','0',NULL),(9600171,'10.10.10.15','','0',NULL),(9600172,'10.10.10.15','','0',NULL),(9600173,'10.10.10.15','','0',NULL),(9600174,'10.10.10.15','','0',NULL),(9600175,'10.10.10.15','','0',NULL),(9600176,'10.10.10.15','','0',NULL),(9600177,'10.10.10.15','','0',NULL),(9600178,'10.10.10.15','','0',NULL),(9600179,'10.10.10.15','','0',NULL),(9600180,'10.10.10.15','','0',NULL),(9600181,'10.10.10.15','','0',NULL),(9600182,'10.10.10.15','','0',NULL),(9600183,'10.10.10.15','','0',NULL),(9600184,'10.10.10.15','','0',NULL),(9600185,'10.10.10.15','','0',NULL),(9600186,'10.10.10.15','','0',NULL),(9600187,'10.10.10.15','','0',NULL),(9600188,'10.10.10.15','','0',NULL),(9600189,'10.10.10.15','','0',NULL),(9600190,'10.10.10.15','','0',NULL),(9600191,'10.10.10.15','','0',NULL),(9600192,'10.10.10.15','','0',NULL),(9600193,'10.10.10.15','','0',NULL),(9600194,'10.10.10.15','','0',NULL),(9600195,'10.10.10.15','','0',NULL),(9600196,'10.10.10.15','','0',NULL),(9600197,'10.10.10.15','','0',NULL),(9600198,'10.10.10.15','','0',NULL),(9600199,'10.10.10.15','','0',NULL),(9600200,'10.10.10.15','','0',NULL),(9600201,'10.10.10.15','','0',NULL),(9600202,'10.10.10.15','','0',NULL),(9600203,'10.10.10.15','','0',NULL),(9600204,'10.10.10.15','','0',NULL),(9600205,'10.10.10.15','','0',NULL),(9600206,'10.10.10.15','','0',NULL),(9600207,'10.10.10.15','','0',NULL),(9600208,'10.10.10.15','','0',NULL),(9600209,'10.10.10.15','','0',NULL),(9600210,'10.10.10.15','','0',NULL),(9600211,'10.10.10.15','','0',NULL),(9600212,'10.10.10.15','','0',NULL),(9600213,'10.10.10.15','','0',NULL),(9600214,'10.10.10.15','','0',NULL),(9600215,'10.10.10.15','','0',NULL),(9600216,'10.10.10.15','','0',NULL),(9600217,'10.10.10.15','','0',NULL),(9600218,'10.10.10.15','','0',NULL),(9600219,'10.10.10.15','','0',NULL),(9600220,'10.10.10.15','','0',NULL),(9600221,'10.10.10.15','','0',NULL),(9600222,'10.10.10.15','','0',NULL),(9600223,'10.10.10.15','','0',NULL),(9600224,'10.10.10.15','','0',NULL),(9600225,'10.10.10.15','','0',NULL),(9600226,'10.10.10.15','','0',NULL),(9600227,'10.10.10.15','','0',NULL),(9600228,'10.10.10.15','','0',NULL),(9600229,'10.10.10.15','','0',NULL),(9600230,'10.10.10.15','','0',NULL),(9600231,'10.10.10.15','','0',NULL),(9600232,'10.10.10.15','','0',NULL),(9600233,'10.10.10.15','','0',NULL),(9600234,'10.10.10.15','','0',NULL),(9600235,'10.10.10.15','','0',NULL),(9600236,'10.10.10.15','','0',NULL),(9600237,'10.10.10.15','','0',NULL),(9600238,'10.10.10.15','','0',NULL),(9600239,'10.10.10.15','','0',NULL),(9600240,'10.10.10.15','','0',NULL),(9600241,'10.10.10.15','','0',NULL),(9600242,'10.10.10.15','','0',NULL),(9600243,'10.10.10.15','','0',NULL),(9600244,'10.10.10.15','','0',NULL),(9600245,'10.10.10.15','','0',NULL),(9600246,'10.10.10.15','','0',NULL),(9600247,'10.10.10.15','','0',NULL),(9600248,'10.10.10.15','','0',NULL),(9600249,'10.10.10.15','','0',NULL),(9600250,'10.10.10.15','','0',NULL),(9600251,'10.10.10.15','','0',NULL),(9600252,'10.10.10.15','','0',NULL),(9600253,'10.10.10.15','','0',NULL),(9600254,'10.10.10.15','','0',NULL),(9600255,'10.10.10.15','','0',NULL),(9600256,'10.10.10.15','','0',NULL),(9600257,'10.10.10.15','','0',NULL),(9600258,'10.10.10.15','','0',NULL),(9600259,'10.10.10.15','','0',NULL),(9600260,'10.10.10.15','','0',NULL),(9600261,'10.10.10.15','','0',NULL),(9600262,'10.10.10.15','','0',NULL),(9600263,'10.10.10.15','','0',NULL),(9600264,'10.10.10.15','','0',NULL),(9600265,'10.10.10.15','','0',NULL),(9600266,'10.10.10.15','','0',NULL),(9600267,'10.10.10.15','','0',NULL),(9600268,'10.10.10.15','','0',NULL),(9600269,'10.10.10.15','','0',NULL),(9600270,'10.10.10.15','','0',NULL),(9600271,'10.10.10.15','','0',NULL),(9600272,'10.10.10.15','','0',NULL),(9600273,'10.10.10.15','','0',NULL),(9600274,'10.10.10.15','','0',NULL),(9600275,'10.10.10.15','','0',NULL),(9600276,'10.10.10.15','','0',NULL),(9600277,'10.10.10.15','','0',NULL),(9600278,'10.10.10.15','','0',NULL),(9600279,'10.10.10.15','','0',NULL),(9600280,'10.10.10.15','','0',NULL),(9600281,'10.10.10.15','','0',NULL),(9600282,'10.10.10.15','','0',NULL),(9600283,'10.10.10.15','','0',NULL),(9600284,'10.10.10.15','','0',NULL),(9600285,'10.10.10.15','','0',NULL),(9600286,'10.10.10.15','','0',NULL),(9600287,'10.10.10.15','','0',NULL),(9600288,'10.10.10.15','','0',NULL),(9600289,'10.10.10.15','','0',NULL),(9600290,'10.10.10.15','','0',NULL),(9600291,'10.10.10.15','','0',NULL),(9600292,'10.10.10.15','','0',NULL),(9600293,'10.10.10.15','','0',NULL),(9600294,'10.10.10.15','','0',NULL),(9600295,'10.10.10.15','','0',NULL),(9600296,'10.10.10.15','','0',NULL),(9600297,'10.10.10.15','','0',NULL),(9600298,'10.10.10.15','','0',NULL),(9600299,'10.10.10.15','','0',NULL);"



finish_stage conferences
fi
echo "Populate AREA CODES"
/usr/share/astguiclient/ADMIN_area_code_populate.pl
# Server and conference rows in the stock seed use 10.10.10.15.
if [[ "$ip_address" != 10.10.10.15 ]]; then
    /usr/share/astguiclient/ADMIN_update_server_ip.pl --old-server_ip=10.10.10.15 --server_ip="$ip_address" --auto
fi
    finish_stage vicidial
fi
if stage_needed boot; then
# Install the jobs only after their programs and the database are ready.
# Keep the VICIdial boot launcher as the single Asterisk startup owner.
install -d /usr/local/sbin /etc/systemd/system
cat > /usr/local/sbin/vicidial-boot <<'BOOT'
#!/usr/bin/env bash
set -e
if [[ -x /usr/share/astguiclient/ip_relay/relay_control ]]; then
    /usr/share/astguiclient/ip_relay/relay_control start
fi
### roll the Asterisk logs upon reboot

/usr/share/astguiclient/ADMIN_restart_roll_logs.pl


### clear the server-related records from the database

/usr/share/astguiclient/AST_reset_mysql_vars.pl


### load dahdi drivers

modprobe dahdi
if modinfo dahdi_dummy >/dev/null 2>&1; then modprobe dahdi_dummy; fi

/usr/sbin/dahdi_cfg -vvvvvvvvvvvvv


### sleep for 20 seconds before launching Asterisk

sleep 20


### start up asterisk

/usr/share/astguiclient/start_asterisk_boot.pl

BOOT
chmod 755 /usr/local/sbin/vicidial-boot
cat > /etc/systemd/system/vicidial-boot.service <<'UNIT'
[Unit]
Description=Start VICIdial telephony
Wants=network-online.target
After=network-online.target mariadb.service httpd.service
Requires=mariadb.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vicidial-boot
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
    finish_stage boot
fi
if stage_needed webphone; then
##Install CyburPhone
cd /var/www/html
if [[ ! -d CyburPhone/.git ]]; then git clone https://github.com/carpenox/CyburPhone.git; fi
chmod -R u+rwX,go+rX CyburPhone
chown -R apache:apache CyburPhone
    finish_stage webphone
fi
if stage_needed portal; then
##Install Dynportal
cd "$work"
wget https://dialer.one/dynportal.zip
wget https://dialer.one/firewall.zip
wget https://dialer.one/aggregate
wget https://dialer.one/VB-firewall

mkdir -p /var/www/vhosts/dynportal
if selinuxenabled; then
    for port in 81 446; do
        if ! semanage port -a -t http_port_t -p tcp "$port" 2>/dev/null; then
            semanage port -m -t http_port_t -p tcp "$port"
        fi
    done
fi
mv "$work"/dynportal.zip /var/www/vhosts/dynportal/
mv "$work"/firewall.zip /etc/firewalld/
cd /var/www/vhosts/dynportal/
unzip -o dynportal.zip
chmod -R 755 *
chown -R apache:apache *
if selinuxenabled; then restorecon -RF /var/www/vhosts/dynportal; fi
cd etc/httpd/conf.d/
mv viciportal.conf /etc/httpd/conf.d/
cd /etc/firewalld/
unzip -o firewall.zip
install -d /etc/firewalld/zones
for zone in public trusted; do
    [[ -s "$zone.xml" ]] || fail "Missing $zone.xml in firewall archive"
done
mv -bf public.xml trusted.xml /etc/firewalld/zones/
mv "$work"/aggregate /usr/bin/
chmod +x /usr/bin/aggregate
mv "$work"/VB-firewall /usr/bin/
chmod +x /usr/bin/VB-firewall


## mv -f /root/defaults.inc.php /var/www/vhosts/dynportal/inc/defaults.inc.php
## mv -f /home/viciportal-ssl.conf /etc/httpd/conf.d/viciportal-ssl.conf

firewall-offline-cmd --check-config
firewall-cmd --reload
firewall-cmd --permanent --zone=public --add-port=446/tcp
    finish_stage portal
fi
if stage_needed ip-relay; then
# Build ip_relay after both fresh installation and explicit recovery.
cd /usr/src/astguiclient/trunk/extras/ip_relay/
unzip -o ip_relay_1.1.112705.zip
cd ip_relay_1.1/src/unix/
grep -Eq '^#[[:space:]]*include[[:space:]]*<unistd.h>' ../lib_ip_relay.c ||
    sed -i '1i #include <unistd.h>' ../lib_ip_relay.c
grep -Eq '^#[[:space:]]*include[[:space:]]*<stdlib.h>' ../ip_relay.c ||
    sed -i '/^#[[:space:]]*include[[:space:]]*<stdio\.h>/a #include <stdlib.h>' ../ip_relay.c
make -B
install -m 0755 ip_relay /usr/bin/ip_relay
install -m 0755 ip_relay /usr/local/bin/ip_relay
    finish_stage ip-relay
fi
if stage_needed audio; then
# Preserve any site-supplied G.729 binary. The original installer used an
# Asterisk 16 binary, which is not a verified codec for this Asterisk 18 build.
if [[ ! -f /usr/lib64/asterisk/modules/codec_g729.so ]]; then
    echo "G.729 codec absent. If required, supply an Asterisk 18 compatible codec."
fi
cat > /etc/httpd/conf.d/vicidial-recordings.conf <<'EOF'
Alias /RECORDINGS/MP3 "/var/spool/asterisk/monitorDONE/MP3/"

<Directory "/var/spool/asterisk/monitorDONE/MP3/">
    Options Indexes MultiViews
    AllowOverride None
    Require all granted
</Directory>
EOF
install -d /var/lib/asterisk/{sounds,moh,mohmp3,quiet-mp3} /var/spool/asterisk/{monitor,monitorDONE/MP3}
cd "$work"
for format in gsm ulaw wav; do
    for family in core-sounds-en extra-sounds-en moh-opsound; do
        archive="asterisk-$family-$format-current.tar.gz"
        target=/var/lib/asterisk/sounds
        if [[ $family == moh-opsound ]]; then target=/var/lib/asterisk/mohmp3; fi
        wget -O "$archive" "https://downloads.asterisk.org/pub/telephony/sounds/$archive"
        tar -xzf "$archive" -C "$target"
    done
done
if [[ ! -e /var/lib/asterisk/default && ! -L /var/lib/asterisk/default ]]; then
    ln -s /var/lib/asterisk/mohmp3 /var/lib/asterisk/default
fi
cd /var/lib/asterisk/quiet-mp3
for src in ../mohmp3/*.{wav,gsm,ulaw}; do
    [[ -f "$src" ]] || continue
    case "$src" in
        *.ulaw) sox -t ul -r 8000 -c 1 "$src" -t ul "${src##*/}" vol 0.25 ;;
        *) sox "$src" "${src##*/}" vol 0.25 ;;
    esac
done
install -d /etc/profile.d
    finish_stage audio
fi
if stage_needed host-config; then
cat > /etc/profile.d/vicidial-status.sh <<'EOF'
if [[ $- == *i* && $(id -u) == 0 ]]; then
/usr/bin/systemctl status httpd --no-pager
/usr/bin/systemctl status firewalld --no-pager
/usr/bin/screen -ls
/usr/sbin/asterisk -V
fi
EOF
sed -i 's|#Banner none|Banner /etc/ssh/sshd_banner|g' /etc/ssh/sshd_config


cat > /etc/ssh/sshd_banner <<EOF
Thank you for choosing Manish's auto installer!

Visit our Knowledge Base at https://manishkadiya.blogspot.com/

Support: manish.23k@gmail.com / https://discord.gg/manishkadiya_81630
Need help? Join the Discord: https://discord.gg/Tbe4dAsX
EOF
getent group asterisk >/dev/null || groupadd --system asterisk
id asterisk >/dev/null 2>&1 || useradd -r -d /var/lib/asterisk -g asterisk asterisk
if ! awk '$1 !~ /^#/ && $2=="/var/spool/asterisk/monitor" {found=1} END{exit !found}' /etc/fstab; then
    echo "tmpfs /var/spool/asterisk/monitor tmpfs nodev,nosuid,noexec,nodiratime,size=2G,mode=0775,uid=$(id -u asterisk),gid=$(getent group asterisk | cut -d: -f3) 0 0" >> /etc/fstab
fi
install -m 644 "$assets/extensions.conf" "$assets/confbridge-vicidial.conf" /etc/asterisk/
grep -Fxq '#include confbridge-vicidial.conf' /etc/asterisk/confbridge.conf ||
    echo '#include confbridge-vicidial.conf' >> /etc/asterisk/confbridge.conf
cat <<WELCOME > /var/www/html/index.html
<META HTTP-EQUIV=REFRESH CONTENT="1; URL=/vicidial/welcome.php">
Please Hold while I redirect you!
WELCOME
mkdir -p /var/www/html/hgcjvmrjzqcngw47wf5zf4xjzd9n0k
cp -r /var/lib/asterisk/sounds/* /var/www/html/hgcjvmrjzqcngw47wf5zf4xjzd9n0k/
if [[ -f /etc/asterisk/pjsip.conf ]]; then
    sed -i "s/SERVER_EXTERNAL_IP/$ip_address/g" /etc/asterisk/pjsip.conf
fi
## add confcron user
sed -i '/^\[confcron\]$/,/^\[/{ /^\[confcron\]$/d; /^\[/!d; }' /etc/asterisk/manager.conf
cat >> /etc/asterisk/manager.conf <<'EOF'

[confcron]
secret = 1234
read = command,reporting
write = command,reporting

eventfilter=Event: Meetme
eventfilter=Event: Confbridge
EOF


firewall-cmd --add-port=10000-20000/udp --permanent
firewall-cmd --add-service=http --permanent --zone=trusted
firewall-cmd --reload
echo "d /run/screen 1777 root root -" > /etc/tmpfiles.d/screen.conf
systemd-tmpfiles --create /etc/tmpfiles.d/screen.conf
    finish_stage host-config
fi
if stage_needed optional-database; then
[[ ! -e "$state/standard-import.started" ]] ||
    fail "The standard database import was interrupted. Review the database and upgrade log before retrying."
read -r -p "Import the optional standard database in place of the fresh seed? [y/N]: " want_db
want_db="${want_db:-N}"

if echo "$want_db" | grep -iq '^y'; then
    curl -fLsS --retry 3 https://cybur-dial.com/downloads/standard-db.zip -o "$work/standard-db.zip"
    unzip -oq "$work/standard-db.zip" -d "$work/standard"
    : > "$state/standard-import.started"
    "${db[@]}" asterisk < "$work/standard/standard-db"
    /usr/share/astguiclient/ADMIN_update_server_ip.pl --old-server_ip=149.28.96.244 --server_ip="$ip_address" --auto
    # The cumulative VICIdial upgrade contains statements for schema elements
    # that may already exist. Keep the transcript and reject unexpected errors.
    upgrade_log=$(mktemp /root/vicidial-upgrade-XXXXXXXX.log)
    "${db[@]}" --force asterisk < /usr/src/astguiclient/trunk/extras/upgrade_2.14.sql 2>"$upgrade_log" || fail "Database upgrade failed. See $upgrade_log"
    if grep '^ERROR' "$upgrade_log" | grep -Ev '^ERROR (1050|1060|1061) ' > "$work/upgrade-errors"; then
        fail "Unexpected SQL error during upgrade. See $upgrade_log"
    fi
    "${db[@]}" asterisk -e "UPDATE vicidial_users SET phone_login=CONCAT(user,'a')"
fi
    finish_stage optional-database
fi
if stage_needed tls-and-routing; then
if [[ -n "$web_domain" ]] && { ! usable_cert_name "$web_domain" || [[ -e "$state/certbot.failed" ]]; }; then
    echo "Certificate setup needs a new choice for the saved name $web_domain."
    choose_web_domain "$web_domain"
    save_settings
    rm -f "$state/certbot.failed"
fi
if [[ -n "$web_domain" ]]; then
    systemctl enable --now certbot-renew.timer
    dnf -y install python3-certbot-apache
    sed "s/DOMAINNAME/$web_domain/g" "$assets/DOMAINNAME.conf" > "/etc/httpd/conf.d/$web_domain.conf"
    httpd -t
    # HTTP-01 uses the same inbound port for issuance and automatic renewals.
    active_zone=$(firewall-cmd --get-default-zone)
    nic=$(ip -4 route show default | awk 'NR==1 {for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}')
    if [[ -n "$nic" ]]; then
        nic_zone=$(firewall-cmd --get-zone-of-interface="$nic" || true)
        if [[ -n "$nic_zone" && "$nic_zone" != 'no zone' ]]; then active_zone="$nic_zone"; fi
    fi
    firewall-cmd --zone="$active_zone" --permanent --add-service=http
    firewall-cmd --zone="$active_zone" --add-service=http
    if ! certbot --apache --cert-name "$web_domain" -d "$web_domain"; then
        touch "$state/certbot.failed"
        fail "Certificate issuance failed. Rerun to retry, change the DNS name, or skip webphone TLS."
    fi
    for conf in http sip; do
        sed "s/DOMAINNAME/$web_domain/g" "$assets/asterisk-$conf.conf" > "/etc/asterisk/$conf.conf"
    done
    cat > /etc/httpd/conf.d/viciportal-ssl.conf <<PORTAL
Listen 446
<VirtualHost *:446>
    ServerName $web_domain
    DocumentRoot "/var/www/vhosts/dynportal"
    DirectoryIndex index.html valid8.php
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$web_domain/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$web_domain/privkey.pem
</VirtualHost>
PORTAL
    sed -i "s/DOMAINNAME/$web_domain/g" /var/www/vhosts/dynportal/inc/defaults.inc.php
    "${db[@]}" asterisk <<SQL
UPDATE vicidial_conf_templates set template_contents='type=friend 
host=dynamic 
context=default 
host=dynamic 
trustrpid=yes 
sendrpid=no 
qualify=yes 
qualifyfreq=600 
transport=ws,wss,udp
encryption=yes
avpf=yes
icesupport=yes
rtcp_mux=yes
directmedia=no
disallow=all
allow=ulaw,opus,vp8,h264
nat=force_rport,comedia
directmedia=no 
dtlsenable=yes
dtlsverify=no
dtlscertfile=/etc/letsencrypt/live/$web_domain/cert.pem
dtlsprivatekey=/etc/letsencrypt/live/$web_domain/privkey.pem
dtlssetup=actpass' where template_id='SIP_generic';
ALTER TABLE phones MODIFY COLUMN is_webphone ENUM('Y','N','Y_API_LAUNCH') DEFAULT 'Y';
UPDATE phones SET template_id='SIP_generic';
SQL
fi
cert_dir="/etc/letsencrypt/live/$web_domain"
if [[ -n "$web_domain" && -s "$cert_dir/fullchain.pem" && -s "$cert_dir/privkey.pem" ]]; then
    install -d /etc/cockpit/ws-certs.d
    install -m 644 "$cert_dir/fullchain.pem" "/etc/cockpit/ws-certs.d/90-$web_domain.cert"
    install -m 600 "$cert_dir/privkey.pem" "/etc/cockpit/ws-certs.d/90-$web_domain.key"
    systemctl restart cockpit.socket
fi
sounds_url="http://$hostname"
if [[ -n "$web_domain" ]]; then sounds_url="https://$web_domain"; fi
"${db[@]}" asterisk <<SQL
UPDATE servers SET external_server_ip='$ip_address', alt_server_ip='$hostname' WHERE server_ip='$ip_address';
UPDATE system_settings SET active_voicemail_server='$ip_address', sounds_web_server='$sounds_url';
SQL
if [[ -n "$web_domain" ]]; then
    "${db[@]}" asterisk <<SQL
UPDATE servers SET web_socket_url='wss://$web_domain:8089/ws' WHERE server_ip='$ip_address';
UPDATE system_settings SET webphone_url='https://$web_domain/CyburPhone/cyburphone.php';
SQL
fi
    finish_stage tls-and-routing
fi
if stage_needed dial-dropdown; then
chown -R asterisk:asterisk /var/spool/asterisk
chmod -R u+rwX,g+rwX,o+rX,o-w /var/spool/asterisk
curl -fsSL --retry 3 https://download.amdy.io/download/dial-dropdown.sh -o "$work/dial-dropdown.sh"
bash "$work/dial-dropdown.sh"
    finish_stage dial-dropdown
fi
if stage_needed services; then
httpd -t
systemctl restart php-fpm httpd
systemctl daemon-reload
systemctl enable --now vicidial-boot.service
for ((attempt=0; attempt<30; attempt++)); do
    if asterisk -rx 'core show uptime' >/dev/null 2>&1; then break; fi
    sleep 1
done
asterisk -rx 'module show like chan_dahdi.so' | grep -E 'chan_dahdi\.so.*Running' ||
    fail "chan_dahdi is not running. Inspect the Asterisk log."
    finish_stage services
fi
if stage_needed cron; then
cat > "$work/cron.jobs" <<'CRONTAB'
### Change dialing to timezones based on zip or postal code (uncomment)
#5 * * * * /usr/bin/mysql -e "use asterisk; update vicidal_lists SET time_zone_setting ='POSTAL_CODE'"

###Audio Sync hourly
0 * * * * /usr/share/astguiclient/ADMIN_audio_store_sync.pl --upload --quiet

### Daily Backups ###
0 2 * * * /usr/share/astguiclient/ADMIN_backup.pl

### Certificate renewal is handled by the certbot systemd timer.

### recording mixing/compressing/ftping scripts
#0,3,6,9,12,15,18,21,24,27,30,33,36,39,42,45,48,51,54,57 * * * * /usr/share/astguiclient/AST_CRON_audio_1_move_mix.pl
0,3,6,9,12,15,18,21,24,27,30,33,36,39,42,45,48,51,54,57 * * * * /usr/share/astguiclient/AST_CRON_audio_1_move_mix.pl --MIX
0,3,6,9,12,15,18,21,24,27,30,33,36,39,42,45,48,51,54,57 * * * * /usr/share/astguiclient/AST_CRON_audio_1_move_VDonly.pl
1,4,7,10,13,16,19,22,25,28,31,34,37,40,43,46,49,52,55,58 * * * * /usr/share/astguiclient/AST_CRON_audio_2_compress.pl --MP3 --HTTPS
#2,5,8,11,14,17,20,23,26,29,32,35,38,41,44,47,50,53,56,59 * * * * /usr/share/astguiclient/AST_CRON_audio_3_ftp.pl --MP3

### keepalive script for astguiclient processes
* * * * * /usr/share/astguiclient/ADMIN_keepalive_ALL.pl

### kill Hangup script for Asterisk updaters
* * * * * /usr/share/astguiclient/AST_manager_kill_hung_congested.pl

### updater for voicemail
* * * * * /usr/share/astguiclient/AST_vm_update.pl

### updater for conference validator
#* * * * * /usr/share/astguiclient/AST_conf_update.pl

### flush queue DB table every hour for entries older than 1 hour
11 * * * * /usr/share/astguiclient/AST_flush_DBqueue.pl -q

### fix the vicidial_agent_log once every hour and the full day run at night
33 * * * * /usr/share/astguiclient/AST_cleanup_agent_log.pl
50 0 * * * /usr/share/astguiclient/AST_cleanup_agent_log.pl --last-24hours

## uncomment below if using QueueMetrics
#*/5 * * * * /usr/share/astguiclient/AST_cleanup_agent_log.pl --only-qm-live-call-check

## uncomment below if using Vtiger
#1 1 * * * /usr/share/astguiclient/Vtiger_optimize_all_tables.pl --quiet

### updater for VICIDIAL hopper
* * * * * /usr/share/astguiclient/AST_VDhopper.pl -q

### adjust the GMT offset for the leads in the vicidial_list table
1 1,7 * * * /usr/share/astguiclient/ADMIN_adjust_GMTnow_on_leads.pl --debug

### reset several temporary-info tables in the database
2 1 * * * /usr/share/astguiclient/AST_reset_mysql_vars.pl

### optimize the database tables within the asterisk database
3 1 * * * /usr/share/astguiclient/AST_DB_optimize.pl

## adjust time on the server with ntp
#30 * * * * /usr/sbin/ntpdate -u pool.ntp.org 2>/dev/null 1>&amp;2

### VICIDIAL agent time log weekly and daily summary report generation
2 0 * * 0 /usr/share/astguiclient/AST_agent_week.pl
22 0 * * * /usr/share/astguiclient/AST_agent_day.pl

### VICIDIAL campaign export scripts (OPTIONAL)
#32 0 * * * /usr/share/astguiclient/AST_VDsales_export.pl
#42 0 * * * /usr/share/astguiclient/AST_sourceID_summary_export.pl

### remove old recordings
#24 0 * * * /usr/bin/find /var/spool/asterisk/monitorDONE -maxdepth 2 -type f -mtime +7 -print | xargs rm -f
#26 1 * * * /usr/bin/find /var/spool/asterisk/monitorDONE/MP3 -maxdepth 2 -type f -mtime +65 -print | xargs rm -f
#25 1 * * * /usr/bin/find /var/spool/asterisk/monitorDONE/FTP -maxdepth 2 -type f -mtime +1 -print | xargs rm -f
24 1 * * * /usr/bin/find /var/spool/asterisk/monitorDONE/ORIG -maxdepth 2 -type f -mtime +1 -print | xargs rm -f


### roll logs monthly on high-volume dialing systems
30 1 1 * * /usr/share/astguiclient/ADMIN_archive_log_tables.pl --days=90

### remove old vicidial logs and asterisk logs more than 2 days old
28 0 * * * /usr/bin/find /var/log/astguiclient -maxdepth 1 -type f -mtime +2 -print | xargs rm -f
29 0 * * * /usr/bin/find /var/log/asterisk -maxdepth 3 -type f -mtime +2 -print | xargs rm -f
30 0 * * * /usr/bin/find / -maxdepth 1 -name "screenlog.0*" -mtime +4 -print | xargs rm -f

### cleanup of the scheduled callback records
25 0 * * * /usr/share/astguiclient/AST_DB_dead_cb_purge.pl --purge-non-cb -q

### GMT adjust script - uncomment to enable
#45 0 * * * /usr/share/astguiclient/ADMIN_adjust_GMTnow_on_leads.pl --list-settings

### Dialer Inventory Report
1 7 * * * /usr/share/astguiclient/AST_dialer_inventory_snapshot.pl -q --override-24hours

### inbound email parser - not enabled by default
#* * * * * /usr/share/astguiclient/AST_inbound_email_parser.pl

### Daily Reboot
#30 6 * * * /sbin/reboot

######TILTIX GARBAGE FILES DELETE
#00 22 * * * root cd /tmp/ && find . -name '*TILTXtmp*' -type f -delete

### Dynportal
@reboot /usr/bin/VB-firewall --whitelist=ViciWhite --dynamic --quiet
* * * * * /usr/bin/VB-firewall --whitelist=ViciWhite --dynamic --quiet
* * * * * sleep 10; /usr/bin/VB-firewall --white --dynamic --quiet
* * * * * sleep 20; /usr/bin/VB-firewall --white --dynamic --quiet
* * * * * sleep 30; /usr/bin/VB-firewall --white --dynamic --quiet
* * * * * sleep 40; /usr/bin/VB-firewall --white --dynamic --quiet
* * * * * sleep 50; /usr/bin/VB-firewall --white --dynamic --quiet


CRONTAB

# cron.d uses a user field. Keep the existing root crontab intact.
awk '/^[[:space:]]*(#|$)/ {print; next} /^@/ {$1=$1 " root"; print; next} {$5=$5 " root"; print}'     "$work/cron.jobs" > "$work/vicidial"
install -m 644 "$work/vicidial" /etc/cron.d/vicidial
systemctl enable --now crond
    finish_stage cron
fi
finish_stage complete
echo "Installation finished."
## XSS Exploit fix
sed -i "7s/.*/echo \"retry: \" . (int)(\$_GET['refresh_interval'] ?? 0) . \"\\\\n\";/" /var/www/html/agc/sse.php

### PHP exploit fix
dnf clean all
dnf update php\* -y

read -r -p 'Reboot now? [y/N] ' answer
case "$answer" in y|Y|yes|YES) systemctl reboot;; esac
