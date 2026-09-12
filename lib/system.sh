#!/usr/bin/env bash
set -Eeuo pipefail

detect_platform() {
    local os_file=$1 arch=$2 key value id='' version=''
    [[ -r $os_file ]] || die 'Cannot read /etc/os-release'
    # Parse data, never source an OS metadata file as shell code.
    while IFS='=' read -r key value; do
        value=${value%\"}; value=${value#\"}
        case $key in ID) id=$value ;; VERSION_ID) version=$value ;; esac
    done < "$os_file"
    [[ $version =~ ^[0-9]+([.][0-9]+)*$ ]] || die 'Invalid OS version'
    case $id in
        debian) (( 10#${version%%.*} >= 12 )) || die 'Debian 12+ required' ;;
        ubuntu)
            [[ $version =~ ^([0-9]+)[.]([0-9]+)$ ]] || die 'Invalid Ubuntu version'
            (( 10#${BASH_REMATCH[1]} > 22 || (10#${BASH_REMATCH[1]} == 22 && 10#${BASH_REMATCH[2]} >= 4) )) || die 'Ubuntu 22.04+ required'
            ;;
        *) die "Unsupported OS: $id; only Debian 12+ and Ubuntu 22.04+" ;;
    esac
    case $arch in
        x86_64|amd64) NF_ARCH=64 ;;
        aarch64|arm64) NF_ARCH=arm64-v8a ;;
        *) die "Unsupported architecture: $arch; only amd64 and arm64" ;;
    esac
    NF_OS=$id NF_OS_VERSION=$version
}
preflight() {
    detect_platform /etc/os-release "$(uname -m)"
    (( EUID == 0 )) || die 'Run as root (sudo bash install.sh)'
    [[ -d /run/systemd/system ]] || die 'A running systemd system is required'
    command -v systemctl >/dev/null || die 'systemctl is required'
    check_paths "${1:-}"
    check_directory_permissions
}
check_directory_permissions() {
    local path permissions
    for path in "$NF_BIN_DIR" "$NF_BIN_DIR/bin" "$NF_CONFIG_DIR" "$NF_DATA_DIR" "$NF_DATA_DIR/backups" "$NF_PENDING"; do
        if [[ -d $path ]]; then
            [[ $(stat -c %u "$path") == 0 ]] || die "Directory not owned by root: $path"
            permissions=$(stat -c %a "$path")
            (( (8#$permissions & 0022) == 0 )) || die "Directory is writable by group/others: $path"
        fi
    done
}
check_paths() {
    local path
    for path in /usr/local /etc /var/lib "$NF_BIN_DIR" "$NF_BIN_DIR/bin" "$NF_CONFIG_DIR" "$NF_DATA_DIR" "$NF_DATA_DIR/backups" "$NF_PENDING"; do
        [[ ! -L $path ]] || die "Refusing symlink: $path"
        [[ ! -e $path || -d $path ]] || die "Expected directory: $path"
    done
    for path in "$NF_BIN" "$NF_LICENSE" "$NF_CONFIG" "$NF_STATE" "$NF_UNIT"; do
        [[ ! -L $path ]] || die "Refusing symlink: $path"
        [[ ! -e $path || -f $path ]] || die "Expected regular file: $path"
    done
    if [[ ${1:-} != uninstall && ! -f $NF_STATE && ! -d $NF_PENDING ]]; then
        for path in "$NF_BIN_DIR" "$NF_CONFIG_DIR" "$NF_DATA_DIR" "$NF_UNIT"; do
            [[ ! -e $path ]] || die "Unmanaged path exists: $path"
        done
    fi
}
install_dependencies() {
    info 'Installing required distribution packages'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl unzip jq openssl iproute2 python3 util-linux
}
acquire_lock() {
    local mode=${1:-exclusive}
    # /run/lock is root-owned on supported systems; do not follow a planted link.
    [[ ! -L /run/lock/nodeforge.lock ]] || die 'Unsafe lock path'
    if [[ ! -e /run/lock/nodeforge.lock ]]; then
        ( set -o noclobber; umask 077; : > /run/lock/nodeforge.lock ) 2>/dev/null || die 'Cannot create stable lock file; retry the operation'
    fi
    trusted_file /run/lock/nodeforge.lock
    exec {NF_LOCK_FD}>>/run/lock/nodeforge.lock
    if [[ $mode == shared ]]; then
        flock -s -n "$NF_LOCK_FD" || die 'Another NodeForge operation is running'
    else
        flock -x -n "$NF_LOCK_FD" || die 'Another NodeForge operation is running'
    fi
}
network_helper() { python3 "$NF_SOURCE/lib/network.py" "$@"; }
validate_port() { [[ $1 =~ ^[1-9][0-9]{3,4}$ ]] && (( 10#$1 >= 1024 && 10#$1 <= 65535 )); }
choose_port() { network_helper choose-port; }
port_available() { network_helper port "$1"; }
resolve_server_ip() {
    local candidate
    if [[ -n ${NODEFORGE_SERVER_IP:-} ]]; then
        candidate=$NODEFORGE_SERVER_IP
    elif [[ -n ${NF_SERVER_IP:-} ]]; then
        candidate=$NF_SERVER_IP
    else
        candidate=$(curl --fail --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 5 --max-time 15 https://api.ipify.org) || die 'IP discovery failed; set NODEFORGE_SERVER_IP'
    fi
    network_helper ip "$candidate" >/dev/null || die 'Server IP must be a public IP literal'
    NF_SERVER_IP=$candidate
}
