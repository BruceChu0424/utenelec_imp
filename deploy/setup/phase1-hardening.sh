#!/usr/bin/env bash
# Uten IMP server Phase 1: host baseline and exact office/VPN UFW policy.
set -Eeuo pipefail
umask 0027
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
export LANG=C
unset CDPATH ENV BASH_ENV PYTHONHOME PYTHONPATH PYTHONUSERBASE

readonly SSH_PORT=22
readonly FIREWALL_CONFIRMATION='ENABLE UFW FOR UTEN IMP'
readonly CONSOLE_CONFIRMATION='TESTED PHYSICAL OR EMERGENCY CONSOLE FOR FIREWALL'
readonly STATE_DIR=/var/lib/uten-imp-commissioning/phase1-firewall
readonly IN_PROGRESS=/var/lib/uten-imp-commissioning/phase1-firewall/in-progress
readonly COMPLETE=/var/lib/uten-imp-commissioning/phase1-firewall/complete
readonly EXPECTED_RULES=/var/lib/uten-imp-commissioning/phase1-firewall/expected-rules
readonly UFW_USER_RULES_SHA256=/var/lib/uten-imp-commissioning/phase1-firewall/ufw-user-rules.sha256
readonly UFW_RUNTIME_SHA256=/var/lib/uten-imp-commissioning/phase1-firewall/ufw-runtime.sha256
readonly LOCK_PATH=/run/uten-imp-host-hardening.lock

office_cidr=''
vpn_cidr=''
firewall_confirmation=''
console_confirmation=''
ssh_client_ip=''
ssh_server_ip=''

die() {
  printf 'PHASE1_REFUSED: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  sudo --preserve-env=SSH_CONNECTION bash phase1-hardening.sh \
    --office-cidr __EXACT_OFFICE_CIDR__ \
    --vpn-cidr __EXACT_VPN_CIDR__ \
    --confirm-firewall 'ENABLE UFW FOR UTEN IMP' \
    --confirm-physical-console 'TESTED PHYSICAL OR EMERGENCY CONSOLE FOR FIREWALL'

Options:
  --office-cidr CIDR       Exact RFC1918/ULA office administration network
  --vpn-cidr CIDR          Exact, non-overlapping RFC1918/ULA corporate VPN
  --confirm-firewall TEXT  Must exactly match the phrase above
  --confirm-physical-console TEXT
                           Required even when running over SSH; confirms a
                           tested recovery console is open
  --help

The script only supports sshd listening on exactly TCP/22. It refuses an
unmanaged existing firewall. Its own interrupted UFW transaction is resumable
only when every existing rule is an exact subset of the persisted approved
rules; any unknown state remains a manual NO-GO. Phase 1 does not change SSH
authentication. Production remains NO-GO until phase1b-ssh-key-only.sh has
installed and committed the exact root-owned administrator keyset. Ubuntu 24.04
must already use direct ssh.service mode; ssh.socket and dynamic firewall agents
(including fail2ban) are refused. Over SSH, run from a direct session (not tmux
or screen) and preserve the real SSH_CONNECTION through sudo.
EOF
}

need_value() {
  [[ "$#" -ge 2 ]] || die "missing value for $1"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --office-cidr) need_value "$@"; office_cidr="$2"; shift 2 ;;
    --vpn-cidr) need_value "$@"; vpn_cidr="$2"; shift 2 ;;
    --confirm-firewall) need_value "$@"; firewall_confirmation="$2"; shift 2 ;;
    --confirm-physical-console) need_value "$@"; console_confirmation="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die 'run as root'
[[ "$firewall_confirmation" == "$FIREWALL_CONFIRMATION" ]] \
  || die "--confirm-firewall must exactly equal: $FIREWALL_CONFIRMATION"
[[ "$console_confirmation" == "$CONSOLE_CONFIRMATION" ]] \
  || die "--confirm-physical-console must exactly equal: $CONSOLE_CONFIRMATION"
[[ -n "$office_cidr" && -n "$vpn_cidr" ]] || die 'both exact CIDRs are required'

require_root_installer() {
  local source_file current source_mode
  [[ ! -L "${BASH_SOURCE[0]}" ]] || die 'refusing to execute phase1 through a symlink'
  source_file="$(realpath -e -- "${BASH_SOURCE[0]}")"
  [[ -f "$source_file" && "$(stat -c '%u:%h' -- "$source_file")" == 0:1 ]] \
    || die 'phase1 installer must be root-owned with one hard link'
  source_mode="$(stat -c '%a' -- "$source_file")"
  (( (8#$source_mode & 0022) == 0 )) || die 'phase1 installer is group- or other-writable'
  current="$(dirname -- "$source_file")"
  while :; do
    [[ -d "$current" && ! -L "$current" && "$(stat -c '%u' -- "$current")" == 0 ]] \
      || die "unsafe phase1 installer directory: $current"
    source_mode="$(stat -c '%a' -- "$current")"
    (( (8#$source_mode & 0022) == 0 )) || die "phase1 installer directory is writable: $current"
    [[ "$current" == / ]] && break
    current="$(dirname -- "$current")"
  done
}

require_root_installer
for required_command in realpath stat flock python3 sshd systemctl ss cmp comm md5sum sha256sum dpkg dpkg-query; do
  command -v "$required_command" >/dev/null 2>&1 || {
    die "required command is unavailable: $required_command"
  }
done

[[ ! -L "$LOCK_PATH" ]] || die "unsafe phase1 lock symlink: $LOCK_PATH"
exec 9>"$LOCK_PATH"
chmod 0600 "$LOCK_PATH"
flock -n 9 || die 'another phase1 firewall transaction is active'

discover_ssh_ancestor_pids() {
  /usr/bin/python3 -I - <<'PY'
import os
import pathlib

pid = os.getppid()
seen = set()
sshd_pids = []
while pid > 1:
    if pid in seen:
        raise SystemExit("process ancestry loop")
    seen.add(pid)
    proc = pathlib.Path("/proc") / str(pid)
    try:
        executable = os.path.realpath(proc / "exe")
        status = (proc / "status").read_text(encoding="utf-8")
    except (FileNotFoundError, PermissionError) as exc:
        raise SystemExit(f"could not prove execution ancestry at PID {pid}: {exc}") from exc
    if executable == "/usr/sbin/sshd":
        sshd_pids.append(str(pid))
    ppid_rows = [line for line in status.splitlines() if line.startswith("PPid:")]
    if len(ppid_rows) != 1:
        raise SystemExit(f"could not parse PPid for PID {pid}")
    pid = int(ppid_rows[0].split()[1])
print(",".join(sshd_pids))
PY
}

verify_ssh_connection_socket() {
  local client_ip="$1" client_port="$2" server_ip="$3" server_port="$4" ancestor_pids="$5"
  /usr/bin/python3 -I - "$client_ip" "$client_port" "$server_ip" "$server_port" "$ancestor_pids" <<'PY'
import ipaddress
import re
import subprocess
import sys

client_raw, client_port, server_raw, server_port, ancestors_raw = sys.argv[1:]
ancestors = set(ancestors_raw.split(",")) - {""}
if not ancestors:
    raise SystemExit("no sshd ancestor PID was supplied")

def normalize(raw):
    value = ipaddress.ip_address(raw.split("%", 1)[0])
    return value.ipv4_mapped or value

def parse_endpoint(token):
    if token.startswith("["):
        closing = token.rfind("]:")
        if closing < 0:
            raise ValueError(token)
        return normalize(token[1:closing]), token[closing + 2:]
    host, port = token.rsplit(":", 1)
    return normalize(host), port

client = normalize(client_raw)
server = normalize(server_raw)
result = subprocess.run(
    ["/usr/bin/ss", "-H", "-tnp", "state", "established"],
    check=True,
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
for row in result.stdout.splitlines():
    endpoints = []
    for token in row.split():
        try:
            endpoints.append(parse_endpoint(token))
        except (ValueError, ipaddress.AddressValueError):
            continue
        if len(endpoints) == 2:
            break
    if len(endpoints) != 2:
        continue
    local, peer = endpoints
    pids = set(re.findall(r"pid=([0-9]+)", row))
    if (local == (server, server_port) and peer == (client, client_port)
            and pids.intersection(ancestors) and '"sshd"' in row):
        break
else:
    raise SystemExit("SSH_CONNECTION does not match an established TCP socket owned by an sshd ancestor")
PY
}

ssh_connection_fields=()
ssh_ancestor_pids="$(discover_ssh_ancestor_pids)" \
  || die 'could not determine whether this is a direct SSH or local-console execution'
if [[ -n "$ssh_ancestor_pids" && -z "${SSH_CONNECTION:-}" ]]; then
  die 'direct SSH execution requires the real SSH_CONNECTION environment; preserve it through sudo'
fi
if [[ -z "$ssh_ancestor_pids" && -n "${SSH_CONNECTION:-}" ]]; then
  die 'SSH_CONNECTION exists without an sshd process ancestor; refusing spoofed session context'
fi
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  read -r -a ssh_connection_fields <<<"$SSH_CONNECTION"
  [[ "${#ssh_connection_fields[@]}" -eq 4 ]] || die 'SSH_CONNECTION must contain exactly four fields'
  ssh_client_ip="${ssh_connection_fields[0]}"
  ssh_server_ip="${ssh_connection_fields[2]}"
  [[ "${ssh_connection_fields[1]}" =~ ^[0-9]+$ && "${ssh_connection_fields[3]}" == "$SSH_PORT" ]] \
    || die 'the current SSH session is not connected to the approved server port 22'
fi

/usr/bin/python3 -I - "$office_cidr" "$vpn_cidr" "$ssh_client_ip" "$ssh_server_ip" <<'PY'
import ipaddress
import sys

office_raw, vpn_raw, client_raw, server_raw = sys.argv[1:]
rfc1918 = tuple(ipaddress.ip_network(value) for value in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))
ula = ipaddress.ip_network("fc00::/7")
networks = []
for label, raw in (("office", office_raw), ("VPN", vpn_raw)):
    try:
        network = ipaddress.ip_network(raw, strict=True)
    except ValueError as exc:
        raise SystemExit(f"{label} CIDR is not canonical: {exc}") from exc
    if raw != str(network):
        raise SystemExit(f"{label} CIDR must use canonical text: {network}")
    allowed = any(network.subnet_of(parent) for parent in rfc1918) if network.version == 4 else network.subnet_of(ula)
    if not allowed or network.is_link_local or network.is_loopback or network.is_multicast or network.is_unspecified:
        raise SystemExit(f"{label} CIDR must be RFC1918 IPv4 or ULA IPv6")
    if network.version == 4 and network.prefixlen < 16:
        raise SystemExit(f"{label} IPv4 CIDR may not be broader than /16")
    if network.version == 6 and network.prefixlen < 48:
        raise SystemExit(f"{label} IPv6 CIDR may not be broader than /48")
    networks.append(network)
if networks[0].version == networks[1].version and networks[0].overlaps(networks[1]):
    raise SystemExit("office and VPN CIDRs must not overlap")
if client_raw:
    try:
        client = ipaddress.ip_address(client_raw)
        server = ipaddress.ip_address(server_raw)
    except ValueError as exc:
        raise SystemExit("SSH_CONNECTION contains an invalid address") from exc
    if not any(client.version == network.version and client in network for network in networks):
        raise SystemExit("current SSH client is outside both approved CIDRs; refusing a lockout")
    if server.is_multicast or server.is_unspecified:
        raise SystemExit("SSH_CONNECTION contains an unsafe server address")
PY

if [[ -n "${SSH_CONNECTION:-}" ]]; then
  verify_ssh_connection_socket "${ssh_connection_fields[0]}" "${ssh_connection_fields[1]}" \
    "${ssh_connection_fields[2]}" "${ssh_connection_fields[3]}" "$ssh_ancestor_pids" \
    || die 'SSH_CONNECTION is not the current kernel TCP/22 session owned by an sshd ancestor'
fi

/usr/sbin/sshd -t
configured_ssh_ports="$(/usr/sbin/sshd -T | awk '$1 == "port" { print $2 }')"
[[ "$configured_ssh_ports" == "$SSH_PORT" ]] \
  || die 'effective sshd configuration must expose exactly TCP/22 before UFW changes'
systemctl is-active --quiet ssh.service || die 'direct ssh.service is not active before the firewall change'
[[ "$(systemctl is-enabled ssh.service)" == enabled ]] \
  || die 'direct ssh.service must be enabled for boot before the firewall change'
systemctl is-active --quiet ssh.socket \
  && die 'ssh.socket is active; perform the separately reviewed console migration to direct ssh.service first'
phase1_socket_enabled="$(systemctl is-enabled ssh.socket 2>/dev/null || true)"
case "$phase1_socket_enabled" in
  disabled|masked|not-found|'') ;;
  *) die "ssh.socket is enabled or activatable: $phase1_socket_enabled" ;;
esac
ss -H -ltnp 'sport = :22' | grep -Fq '"sshd"' \
  || die 'sshd is not the process listening on the approved SSH port 22'

fsync_path() {
  /usr/bin/python3 -I - "$1" <<'PY'
import os
import sys

path = sys.argv[1]
flags = os.O_RDONLY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
fd = os.open(path, flags)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

atomic_install() {
  local source_path="$1" destination="$2" owner="$3" group="$4" file_mode="$5"
  local destination_dir temporary
  destination_dir="$(dirname -- "$destination")" || return 1
  temporary="$(mktemp "$destination_dir/.uten-phase1-install.XXXXXX")" || return 1
  if ! install -o "$owner" -g "$group" -m "$file_mode" -- "$source_path" "$temporary"; then
    rm -f -- "$temporary" >/dev/null 2>&1 || :
    return 1
  fi
  if ! fsync_path "$temporary"; then
    rm -f -- "$temporary" >/dev/null 2>&1 || :
    return 1
  fi
  if ! mv -fT -- "$temporary" "$destination"; then
    rm -f -- "$temporary" >/dev/null 2>&1 || :
    return 1
  fi
  fsync_path "$destination" || return 1
  fsync_path "$destination_dir" || return 1
  return 0
}

atomic_remove() {
  local destination="$1" destination_dir
  destination_dir="$(dirname -- "$destination")" || return 1
  if [[ -e "$destination" || -L "$destination" ]]; then
    rm -f -- "$destination" || return 1
    fsync_path "$destination_dir" || return 1
  fi
  return 0
}

validate_root_directory() {
  local directory="$1" directory_mode
  [[ -d "$directory" && ! -L "$directory" && "$(stat -c '%u' -- "$directory")" == 0 ]] \
    || die "unsafe phase1 state directory: $directory"
  directory_mode="$(stat -c '%a' -- "$directory")"
  (( (8#$directory_mode & 0022) == 0 )) || die "phase1 state directory is writable: $directory"
}

echo '==> Time zone and NTP'
timedatectl set-timezone Asia/Shanghai
timedatectl set-ntp true

echo '==> Unattended security updates'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq unattended-upgrades apt-listchanges >/dev/null
validate_root_directory /etc
validate_root_directory /etc/apt
validate_root_directory /etc/apt/apt.conf.d
apt_periodic_candidate="$(mktemp /run/uten-imp-apt-periodic.XXXXXX)"
cat >"$apt_periodic_candidate" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
atomic_install "$apt_periodic_candidate" /etc/apt/apt.conf.d/20auto-upgrades 0 0 0644
rm -f -- "$apt_periodic_candidate"
apt_unattended_candidate="$(mktemp /run/uten-imp-apt-unattended.XXXXXX)"
cat >"$apt_unattended_candidate" <<'EOF'
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
atomic_install "$apt_unattended_candidate" /etc/apt/apt.conf.d/51uten-unattended 0 0 0644
rm -f -- "$apt_unattended_candidate"
systemctl enable --now unattended-upgrades

echo '==> Baseline tools'
apt-get install -y -qq curl jq ca-certificates gnupg >/dev/null

echo '==> UFW exact office/VPN policy'
apt-get install -y -qq ufw >/dev/null
for required_command in ufw iptables ip6tables iptables-save ip6tables-save nft; do
  command -v "$required_command" >/dev/null 2>&1 || die "required UFW command is unavailable: $required_command"
done
[[ -f /etc/default/ufw && ! -L /etc/default/ufw ]] \
  || die '/etc/default/ufw must be a regular, non-symlink file'
[[ "$(stat -c '%u:%g:%a:%h' -- /etc/default/ufw)" == 0:0:644:1 ]] \
  || die '/etc/default/ufw must be root:root mode 0644 with one hard link'
[[ "$(grep -Ec '^IPV6=yes$' /etc/default/ufw)" == 1 ]] \
  || die '/etc/default/ufw must contain exactly one IPV6=yes'

validate_root_directory /var
validate_root_directory /var/lib
if [[ -e /var/lib/uten-imp-commissioning || -L /var/lib/uten-imp-commissioning ]]; then
  validate_root_directory /var/lib/uten-imp-commissioning
fi
install -d -o 0 -g 0 -m 0700 /var/lib/uten-imp-commissioning
validate_root_directory /var/lib/uten-imp-commissioning
fsync_path /var/lib
if [[ -e "$STATE_DIR" || -L "$STATE_DIR" ]]; then
  validate_root_directory "$STATE_DIR"
fi
install -d -o 0 -g 0 -m 0700 "$STATE_DIR"
validate_root_directory "$STATE_DIR"
fsync_path /var/lib/uten-imp-commissioning
fsync_path "$STATE_DIR"

validate_root_regular_file() {
  local file_path="$1" exact_mode="$2"
  [[ -f "$file_path" && ! -L "$file_path" \
    && "$(stat -c '%u:%g:%a:%h' -- "$file_path")" == "0:0:$exact_mode:1" ]] \
    || die "unsafe root-owned file: $file_path"
}

verify_dpkg_conffile() {
  local file_path="$1" record recorded_md5 status actual_md5
  record="$(dpkg-query -W -f='${Conffiles}\n' ufw | awk -v path="$file_path" '$1 == path { print $2 " " $3 }')"
  [[ -n "$record" ]] || die "ufw package has no recorded conffile digest for $file_path"
  read -r recorded_md5 status <<<"$record"
  [[ "$recorded_md5" =~ ^[0-9a-f]{32}$ && "$status" != obsolete ]] \
    || die "invalid or obsolete ufw conffile record for $file_path"
  actual_md5="$(md5sum -- "$file_path" | awk '{ print $1 }')"
  [[ "$actual_md5" == "$recorded_md5" ]] \
    || die "ufw conffile differs from the installed package baseline: $file_path"
}

verify_disabled_firewall_service() {
  local unit="$1" active_state enabled_state load_state
  active_state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  case "$active_state" in
    inactive|failed) ;;
    active|activating|reloading|deactivating) die "competing firewall service is active: $unit ($active_state)" ;;
    *)
      load_state="$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)"
      [[ "$load_state" == not-found ]] \
        || die "could not prove competing firewall service inactive: $unit ($active_state/$load_state)"
      ;;
  esac
  enabled_state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  case "$enabled_state" in
    disabled|masked|not-found) ;;
    '')
      load_state="${load_state:-$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)}"
      [[ "$load_state" == not-found ]] || die "could not prove firewall service disabled: $unit"
      ;;
    *) die "competing firewall service is enabled or activatable: $unit ($enabled_state)" ;;
  esac
}

verify_ufw_framework_baseline() {
  local os_id os_version package_status package_verify_output relative source_path installed_path
  os_id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
  os_version="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')"
  [[ "$os_id" == ubuntu && "$os_version" == 24.04 ]] \
    || die 'the audited UFW framework contract only supports Ubuntu 24.04'
  package_status="$(dpkg-query -W -f='${db:Status-Status}' ufw 2>/dev/null)"
  [[ "$package_status" == installed ]] || die 'ufw package is not fully installed'
  package_verify_output="$(dpkg --verify ufw 2>&1)" \
    || die 'dpkg could not verify the installed ufw package'
  [[ -z "$package_verify_output" ]] \
    || die 'installed ufw package files or conffiles differ from dpkg-recorded bytes'
  validate_root_directory /etc
  validate_root_directory /etc/default
  validate_root_directory /etc/ufw
  validate_root_directory /usr
  validate_root_directory /usr/share
  validate_root_directory /usr/share/ufw
  validate_root_regular_file /etc/default/ufw 644
  validate_root_regular_file /etc/ufw/sysctl.conf 644
  verify_dpkg_conffile /etc/default/ufw
  verify_dpkg_conffile /etc/ufw/sysctl.conf
  for relative in before.rules before6.rules after.rules after6.rules before.init after.init; do
    source_path="/usr/share/ufw/$relative"
    installed_path="/etc/ufw/$relative"
    validate_root_regular_file "$source_path" 644
    validate_root_regular_file "$installed_path" 640
    cmp -s -- "$installed_path" "$source_path" \
      || die "custom UFW framework bytes are forbidden without an independent firewall migration: $installed_path"
  done
  [[ "$(grep -Ec '^IPV6=yes$' /etc/default/ufw)" == 1 ]] \
    || die '/etc/default/ufw must contain exactly one IPV6=yes'
  verify_disabled_firewall_service nftables.service
  verify_disabled_firewall_service firewalld.service
  verify_disabled_firewall_service netfilter-persistent.service
  verify_disabled_firewall_service fail2ban.service
}

validate_ufw_user_files() {
  validate_root_regular_file /etc/ufw/user.rules 640
  validate_root_regular_file /etc/ufw/user6.rules 640
}

verify_pristine_ufw_user_files() {
  validate_ufw_user_files
  cmp -s -- /etc/ufw/user.rules /usr/share/ufw/user.rules \
    || die 'inactive UFW IPv4 user rules are not the pristine package skeleton'
  cmp -s -- /etc/ufw/user6.rules /usr/share/ufw/user6.rules \
    || die 'inactive UFW IPv6 user rules are not the pristine package skeleton'
}

render_ufw_user_checkpoint() {
  local destination="$1"
  validate_ufw_user_files
  sha256sum -- /etc/ufw/user.rules /etc/ufw/user6.rules >"$destination" || return 1
  chmod 0600 "$destination" || return 1
  fsync_path "$destination" || return 1
}

write_ufw_user_checkpoint() {
  local candidate
  candidate="$(mktemp /run/uten-imp-ufw-user-sha.XXXXXX)" || return 1
  if ! render_ufw_user_checkpoint "$candidate"; then
    rm -f -- "$candidate" >/dev/null 2>&1 || :
    return 1
  fi
  if ! atomic_install "$candidate" "$UFW_USER_RULES_SHA256" 0 0 0600; then
    rm -f -- "$candidate" >/dev/null 2>&1 || :
    return 1
  fi
  rm -f -- "$candidate" || return 1
}

verify_ufw_user_checkpoint() {
  local candidate
  [[ -f "$UFW_USER_RULES_SHA256" && ! -L "$UFW_USER_RULES_SHA256" \
    && "$(stat -c '%u:%g:%a:%h' -- "$UFW_USER_RULES_SHA256")" == 0:0:600:1 ]] || return 1
  candidate="$(mktemp /run/uten-imp-ufw-user-verify.XXXXXX)" || return 1
  if ! render_ufw_user_checkpoint "$candidate"; then
    rm -f -- "$candidate" >/dev/null 2>&1 || :
    return 1
  fi
  if ! cmp -s -- "$candidate" "$UFW_USER_RULES_SHA256"; then
    rm -f -- "$candidate" >/dev/null 2>&1 || :
    return 1
  fi
  rm -f -- "$candidate" || return 1
}

run_ufw_mutation() {
  verify_ufw_framework_baseline
  verify_ufw_user_checkpoint \
    || die 'UFW user-rule bytes changed outside the durable Phase1 transaction; manual NO-GO'
  if ! ufw "$@"; then
    die "UFW mutation failed; the durable checkpoint remains for manual recovery: ufw $*"
  fi
  write_ufw_user_checkpoint \
    || die 'UFW changed but its new user-rule checkpoint was not durably committed; manual NO-GO'
  verify_ufw_framework_baseline
}

capture_firewall_runtime() {
  local raw4="$1" raw6="$2" nft_rules="$3" nft_tables="$4"
  iptables-save | sed -e '/^# Generated by /d' -e '/^# Completed on /d' >"$raw4" || return 1
  ip6tables-save | sed -e '/^# Generated by /d' -e '/^# Completed on /d' >"$raw6" || return 1
  nft --stateless list ruleset >"$nft_rules" || return 1
  nft list tables | sort >"$nft_tables" || return 1
  fsync_path "$raw4" || return 1
  fsync_path "$raw6" || return 1
  fsync_path "$nft_rules" || return 1
  fsync_path "$nft_tables" || return 1
}

verify_pristine_runtime_firewall() {
  local raw4 raw6 nft_rules nft_tables
  raw4="$(mktemp /run/uten-imp-fw-pristine4.XXXXXX)" || return 1
  raw6="$(mktemp /run/uten-imp-fw-pristine6.XXXXXX)" || return 1
  nft_rules="$(mktemp /run/uten-imp-fw-pristine-nft.XXXXXX)" || return 1
  nft_tables="$(mktemp /run/uten-imp-fw-pristine-tables.XXXXXX)" || return 1
  capture_firewall_runtime "$raw4" "$raw6" "$nft_rules" "$nft_tables" || return 1
  /usr/bin/python3 -I - "$raw4" "$raw6" <<'PY' || return 1
import pathlib
import sys

for path_raw in sys.argv[1:]:
    table = None
    for raw in pathlib.Path(path_raw).read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("*"):
            table = line[1:]
            if table != "filter":
                raise SystemExit(f"unexpected pre-Phase1 netfilter table: {table}")
            continue
        if line == "COMMIT":
            table = None
            continue
        if table == "filter" and line.startswith(":"):
            fields = line.split()
            chain, policy = fields[0][1:], fields[1]
            if chain not in {"INPUT", "FORWARD", "OUTPUT"} or policy != "ACCEPT":
                raise SystemExit(f"non-pristine pre-Phase1 chain: {line}")
        elif table == "filter" and line.startswith("-A "):
            raise SystemExit(f"pre-Phase1 netfilter rule exists: {line}")
        elif table is not None:
            raise SystemExit(f"unrecognized pre-Phase1 netfilter bytes: {line}")
PY
  [[ ! -s "$nft_tables" && ! -s "$nft_rules" ]] || return 1
  rm -f -- "$raw4" "$raw6" "$nft_rules" "$nft_tables" || return 1
}

validate_active_runtime_graph() {
  local raw4="$1" raw6="$2" nft_tables="$3" backend4 backend6 expected_tables
  /usr/bin/python3 -I - "$raw4" "$raw6" <<'PY' || return 1
import pathlib
import shlex
import sys

for path_raw in sys.argv[1:]:
    table = None
    policies = {}
    ufw_chain = False
    ufw_jump = False
    tables = set()
    for raw in pathlib.Path(path_raw).read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("*"):
            table = line[1:]
            tables.add(table)
            if table != "filter":
                raise SystemExit(f"unexpected live netfilter table: {table}")
            continue
        if line == "COMMIT":
            table = None
            continue
        if table != "filter":
            if table is not None:
                raise SystemExit(f"unrecognized live netfilter bytes: {line}")
            continue
        if line.startswith(":"):
            fields = line.split()
            chain, policy = fields[0][1:], fields[1]
            if chain in {"INPUT", "FORWARD", "OUTPUT"}:
                policies[chain] = policy
            elif chain.startswith(("ufw-", "ufw6-")):
                ufw_chain = True
            else:
                raise SystemExit(f"foreign live filter chain: {chain}")
            continue
        if line.startswith("-A "):
            fields = shlex.split(line)
            chain = fields[1]
            if chain not in {"INPUT", "FORWARD", "OUTPUT"} and not chain.startswith(("ufw-", "ufw6-")):
                raise SystemExit(f"rule uses a foreign live chain: {chain}")
            if chain in {"INPUT", "FORWARD", "OUTPUT"}:
                try:
                    target = fields[fields.index("-j") + 1]
                except (ValueError, IndexError) as exc:
                    raise SystemExit(f"built-in rule has no auditable jump: {line}") from exc
                if not target.startswith(("ufw-", "ufw6-")):
                    raise SystemExit(f"built-in chain bypasses UFW: {line}")
                ufw_jump = True
            continue
        raise SystemExit(f"unrecognized live filter bytes: {line}")
    expected = {"INPUT": "DROP", "FORWARD": "DROP", "OUTPUT": "ACCEPT"}
    if tables != {"filter"} or policies != expected or not ufw_chain or not ufw_jump:
        raise SystemExit("live UFW filter graph is incomplete or has unsafe policies")
PY
  backend4="$(iptables --version)" || return 1
  backend6="$(ip6tables --version)" || return 1
  if [[ "$backend4" == *'(nf_tables)'* && "$backend6" == *'(nf_tables)'* ]]; then
    expected_tables=$'table ip filter\ntable ip6 filter'
    [[ "$(<"$nft_tables")" == "$expected_tables" ]] || return 1
  elif [[ "$backend4" == *'(legacy)'* && "$backend6" == *'(legacy)'* ]]; then
    [[ ! -s "$nft_tables" ]] || return 1
  else
    return 1
  fi
}

render_runtime_checkpoint() {
  local destination="$1" raw4 raw6 nft_rules nft_tables hash4 hash6 nft_hash
  raw4="$(mktemp /run/uten-imp-fw-runtime4.XXXXXX)" || return 1
  raw6="$(mktemp /run/uten-imp-fw-runtime6.XXXXXX)" || return 1
  nft_rules="$(mktemp /run/uten-imp-fw-runtime-nft.XXXXXX)" || return 1
  nft_tables="$(mktemp /run/uten-imp-fw-runtime-tables.XXXXXX)" || return 1
  capture_firewall_runtime "$raw4" "$raw6" "$nft_rules" "$nft_tables" || return 1
  validate_active_runtime_graph "$raw4" "$raw6" "$nft_tables" || return 1
  hash4="$(sha256sum -- "$raw4" | awk '{ print $1 }')" || return 1
  hash6="$(sha256sum -- "$raw6" | awk '{ print $1 }')" || return 1
  nft_hash="$(sha256sum -- "$nft_rules" | awk '{ print $1 }')" || return 1
  printf 'iptables_sha256=%s\nip6tables_sha256=%s\nnft_stateless_sha256=%s\n' \
    "$hash4" "$hash6" "$nft_hash" >"$destination" || return 1
  chmod 0600 "$destination" || return 1
  fsync_path "$destination" || return 1
  rm -f -- "$raw4" "$raw6" "$nft_rules" "$nft_tables" || return 1
}

write_runtime_checkpoint() {
  local candidate
  candidate="$(mktemp /run/uten-imp-fw-runtime-sha.XXXXXX)" || return 1
  render_runtime_checkpoint "$candidate" || return 1
  atomic_install "$candidate" "$UFW_RUNTIME_SHA256" 0 0 0600 || return 1
  rm -f -- "$candidate" || return 1
}

verify_runtime_checkpoint() {
  local candidate
  [[ -f "$UFW_RUNTIME_SHA256" && ! -L "$UFW_RUNTIME_SHA256" \
    && "$(stat -c '%u:%g:%a:%h' -- "$UFW_RUNTIME_SHA256")" == 0:0:600:1 ]] || return 1
  candidate="$(mktemp /run/uten-imp-fw-runtime-verify.XXXXXX)" || return 1
  render_runtime_checkpoint "$candidate" || return 1
  cmp -s -- "$candidate" "$UFW_RUNTIME_SHA256" || return 1
  rm -f -- "$candidate" || return 1
}

verify_final_ufw_conf() {
  local candidate
  validate_root_regular_file /etc/ufw/ufw.conf 644
  [[ "$(grep -Ec '^ENABLED=' /usr/share/ufw/ufw.conf)" == 1 \
    && "$(grep -Ec '^LOGLEVEL=' /usr/share/ufw/ufw.conf)" == 1 ]] \
    || die 'the installed ufw.conf skeleton is not auditable'
  candidate="$(mktemp /run/uten-imp-ufw-conf.XXXXXX)"
  sed -e 's/^ENABLED=.*/ENABLED=yes/' -e 's/^LOGLEVEL=.*/LOGLEVEL=medium/' \
    /usr/share/ufw/ufw.conf >"$candidate"
  cmp -s -- "$candidate" /etc/ufw/ufw.conf || {
    rm -f -- "$candidate"
    die '/etc/ufw/ufw.conf differs from the exact enabled/medium package-derived contract'
  }
  rm -f -- "$candidate"
}

request_state="$(mktemp /run/uten-imp-phase1-state.XXXXXX)"
printf 'office_cidr=%s\nvpn_cidr=%s\nssh_port=%s\n' "$office_cidr" "$vpn_cidr" "$SSH_PORT" >"$request_state"
chmod 0600 "$request_state"

expected_rules_candidate="$(mktemp /run/uten-imp-phase1-rules.XXXXXX)"
for approved_cidr in "$office_cidr" "$vpn_cidr"; do
  printf "ufw allow from %s to any port 22 proto tcp comment 'uten-admin-ssh'\n" "$approved_cidr"
  printf "ufw allow from %s to any port 80 proto tcp comment 'uten-http-redirect'\n" "$approved_cidr"
  printf "ufw allow from %s to any port 443 proto tcp comment 'uten-erp-https'\n" "$approved_cidr"
done | sort >"$expected_rules_candidate"
chmod 0600 "$expected_rules_candidate"

current_added_rules() {
  local destination="$1"
  ufw show added 2>/dev/null | sed -n '/^ufw[[:space:]]/p' | sort >"$destination"
}

verify_ufw_framework_baseline
ufw_status_line="$(ufw status | sed -n '1p')"
current_rules_probe="$(mktemp /run/uten-imp-phase1-current-rules.XXXXXX)"
current_added_rules "$current_rules_probe"

if [[ -e "$IN_PROGRESS" || -L "$IN_PROGRESS" ]]; then
  verify_ufw_user_checkpoint \
    || die 'phase1 in-progress UFW user-rule checkpoint differs; manual NO-GO'
  [[ -f "$IN_PROGRESS" && ! -L "$IN_PROGRESS" && "$(stat -c '%u:%g:%a:%h' -- "$IN_PROGRESS")" == 0:0:600:1 ]] \
    || die 'unsafe phase1 in-progress marker; keep the physical console open and stop'
  cmp -s -- "$IN_PROGRESS" "$request_state" \
    || die 'phase1 in-progress policy differs from this request; keep the physical console open and stop'
  [[ -f "$EXPECTED_RULES" && ! -L "$EXPECTED_RULES" && "$(stat -c '%u:%g:%a:%h' -- "$EXPECTED_RULES")" == 0:0:600:1 ]] \
    || die 'phase1 expected-rule evidence is missing or unsafe'
  cmp -s -- "$EXPECTED_RULES" "$expected_rules_candidate" \
    || die 'persisted phase1 expected rules differ from this request'
  if [[ -e "$COMPLETE" || -L "$COMPLETE" ]]; then
    [[ -f "$COMPLETE" && ! -L "$COMPLETE" && "$(stat -c '%u:%g:%a:%h' -- "$COMPLETE")" == 0:0:600:1 ]] \
      || die 'unsafe phase1 complete-state file beside the in-progress marker'
    cmp -s -- "$COMPLETE" "$request_state" \
      || die 'phase1 complete state differs from its interrupted transaction'
  fi
  unknown_rules="$(comm -23 "$current_rules_probe" "$EXPECTED_RULES")"
  [[ -z "$unknown_rules" ]] || die 'interrupted UFW policy contains an unapproved rule; manual NO-GO'
elif [[ -e "$COMPLETE" || -L "$COMPLETE" ]]; then
  verify_ufw_user_checkpoint \
    || die 'completed phase1 UFW user-rule checkpoint differs; manual NO-GO'
  [[ -f "$COMPLETE" && ! -L "$COMPLETE" && "$(stat -c '%u:%g:%a:%h' -- "$COMPLETE")" == 0:0:600:1 ]] \
    || die 'unsafe phase1 complete-state file'
  cmp -s -- "$COMPLETE" "$request_state" \
    || die 'completed phase1 policy differs from this request'
  [[ -f "$EXPECTED_RULES" && ! -L "$EXPECTED_RULES" && "$(stat -c '%u:%g:%a:%h' -- "$EXPECTED_RULES")" == 0:0:600:1 ]] \
    || die 'completed phase1 expected-rule evidence is missing or unsafe'
  cmp -s -- "$EXPECTED_RULES" "$expected_rules_candidate" \
    || die 'completed phase1 expected rules differ from this request'
  [[ "$ufw_status_line" == 'Status: active' ]] \
    || die 'completed phase1 policy is not active; manual review is required before re-enabling it'
  cmp -s -- "$current_rules_probe" "$EXPECTED_RULES" \
    || die 'active UFW rules differ from the completed exact policy'
else
  for orphaned_evidence in "$EXPECTED_RULES" "$UFW_USER_RULES_SHA256" "$UFW_RUNTIME_SHA256"; do
    [[ ! -e "$orphaned_evidence" && ! -L "$orphaned_evidence" ]] \
      || die "orphaned phase1 evidence requires console review before a fresh firewall transaction: $orphaned_evidence"
  done
  [[ "$ufw_status_line" == 'Status: inactive' ]] \
    || die 'an unmanaged active UFW policy already exists; review it under a separate change'
  [[ ! -s "$current_rules_probe" ]] \
    || die 'inactive UFW already contains unmanaged rules; this script never resets a firewall'
  verify_pristine_ufw_user_files
  verify_pristine_runtime_firewall \
    || die 'pre-Phase1 kernel firewall state is not pristine; use an independent firewall migration'
  write_ufw_user_checkpoint \
    || die 'could not durably checkpoint pristine UFW user-rule bytes'
  atomic_install "$expected_rules_candidate" "$EXPECTED_RULES" 0 0 0600
  atomic_install "$request_state" "$IN_PROGRESS" 0 0 0600
fi

if [[ -e "$IN_PROGRESS" && ! -L "$IN_PROGRESS" ]]; then
  ensure_rule() {
    local cidr="$1" port="$2" comment="$3" expected_line="$4" probe
    probe="$(mktemp /run/uten-imp-phase1-rule-check.XXXXXX)"
    current_added_rules "$probe"
    if ! grep -Fxq "$expected_line" "$probe"; then
      run_ufw_mutation allow from "$cidr" to any port "$port" proto tcp comment "$comment"
    fi
    rm -f -- "$probe"
  }

  run_ufw_mutation default deny incoming
  run_ufw_mutation default allow outgoing
  for approved_cidr in "$office_cidr" "$vpn_cidr"; do
    ensure_rule "$approved_cidr" 22 uten-admin-ssh \
      "ufw allow from $approved_cidr to any port 22 proto tcp comment 'uten-admin-ssh'"
    ensure_rule "$approved_cidr" 80 uten-http-redirect \
      "ufw allow from $approved_cidr to any port 80 proto tcp comment 'uten-http-redirect'"
    ensure_rule "$approved_cidr" 443 uten-erp-https \
      "ufw allow from $approved_cidr to any port 443 proto tcp comment 'uten-erp-https'"
  done
  run_ufw_mutation logging medium
  current_added_rules "$current_rules_probe"
  cmp -s -- "$current_rules_probe" "$EXPECTED_RULES" \
    || die 'staged UFW rules do not exactly equal the approved rule set; persistent NO-GO remains'
  ufw_status_line="$(ufw status | sed -n '1p')"
  if [[ "$ufw_status_line" == 'Status: inactive' ]]; then
    run_ufw_mutation --force enable
  elif [[ "$ufw_status_line" != 'Status: active' ]]; then
    die 'UFW status is neither active nor inactive; keep the console open and stop'
  fi
  run_ufw_mutation reload
fi

verify_ufw_policy() {
  local raw current_verify
  verify_ufw_framework_baseline
  verify_ufw_user_checkpoint \
    || die 'live UFW user-rule bytes differ from the durable checkpoint'
  verify_final_ufw_conf
  [[ "$(ufw status | sed -n '1p')" == 'Status: active' ]] || die 'UFW did not become active'
  systemctl is-active --quiet ufw.service || die 'ufw.service is not active after policy activation'
  [[ "$(systemctl is-enabled ufw.service)" == enabled ]] || die 'ufw.service is not enabled for boot'
  ufw status verbose | grep -Eq 'Default:[[:space:]]+deny \(incoming\), allow \(outgoing\)' \
    || die 'UFW default policy differs from deny-incoming/allow-outgoing'
  current_verify="$(mktemp /run/uten-imp-phase1-verify-rules.XXXXXX)"
  current_added_rules "$current_verify"
  cmp -s -- "$current_verify" "$EXPECTED_RULES" || {
    rm -f -- "$current_verify"
    die 'active UFW rules differ from the exact approved rule set'
  }
  rm -f -- "$current_verify"
  raw="$(ufw show raw)"
  awk '
    /^IPV4 \(raw\):/ { family="v4"; next }
    /^IPV6 \(raw\):/ { family="v6"; next }
    family == "v4" && /^Chain INPUT \(policy DROP([[:space:]]|\))/ { v4=1 }
    family == "v6" && /^Chain INPUT \(policy DROP([[:space:]]|\))/ { v6=1 }
    END { exit(v4 && v6 ? 0 : 1) }
  ' <<<"$raw" || die 'UFW IPv4/IPv6 INPUT policies are not both DROP'
}

verify_ufw_policy
if [[ -e "$IN_PROGRESS" && ! -L "$IN_PROGRESS" ]]; then
  write_runtime_checkpoint \
    || die 'could not durably checkpoint the exact live IPv4/IPv6/nft UFW ruleset'
  verify_runtime_checkpoint \
    || die 'live UFW runtime differs immediately after its durable checkpoint'
  atomic_install "$request_state" "$COMPLETE" 0 0 0600
  atomic_remove "$IN_PROGRESS"
else
  verify_runtime_checkpoint \
    || die 'completed phase1 live UFW runtime differs from its durable exact checkpoint'
fi
rm -f -- "$request_state" "$expected_rules_candidate" "$current_rules_probe"

echo '==> Phase 1 host/firewall baseline complete'
timedatectl | head -4
systemctl is-active unattended-upgrades ssh.service
ufw status verbose
printf '%s\n' 'PHASE1_SSH_NO_GO: SSH authentication was not changed. Production remains NO-GO until phase1b-ssh-key-only.sh completes state=key-only.'
