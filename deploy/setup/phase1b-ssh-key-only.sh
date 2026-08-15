#!/usr/bin/env bash
# Uten IMP SSH Phase 1b: install an exact root-owned administrator keyset,
# then explicitly commit key-only authentication after both keys are tested.
set -Eeuo pipefail
umask 0077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
export LANG=C
unset CDPATH ENV BASH_ENV PYTHONHOME PYTHONPATH PYTHONUSERBASE

readonly SSH_PORT=22
readonly CONFIG_DIR=/etc/ssh/sshd_config.d
readonly CONFIG_PATH=/etc/ssh/sshd_config.d/00-uten-imp.conf
readonly AUTHORIZED_KEYS_DIR=/etc/ssh/authorized_keys
readonly STATE_DIR=/var/lib/uten-imp-commissioning/ssh-key-only
readonly TRANSACTION_ROOT=/var/lib/uten-imp-commissioning/ssh-key-only/transactions
readonly IN_PROGRESS=/var/lib/uten-imp-commissioning/ssh-key-only/in-progress
readonly COMPLETE=/var/lib/uten-imp-commissioning/ssh-key-only/complete
readonly PHASE1_FIREWALL_DIR=/var/lib/uten-imp-commissioning/phase1-firewall
readonly PHASE1_FIREWALL_IN_PROGRESS=/var/lib/uten-imp-commissioning/phase1-firewall/in-progress
readonly PHASE1_FIREWALL_COMPLETE=/var/lib/uten-imp-commissioning/phase1-firewall/complete
readonly PHASE1_FIREWALL_EXPECTED_RULES=/var/lib/uten-imp-commissioning/phase1-firewall/expected-rules
readonly PHASE1_UFW_USER_RULES_SHA256=/var/lib/uten-imp-commissioning/phase1-firewall/ufw-user-rules.sha256
readonly PHASE1_UFW_RUNTIME_SHA256=/var/lib/uten-imp-commissioning/phase1-firewall/ufw-runtime.sha256
readonly LOCK_PATH=/run/uten-imp-host-hardening.lock
readonly PASSWORD_CONFIRMATION='ROTATED DISCLOSED SERVER PASSWORD OUT OF BAND'
readonly CONSOLE_CONFIRMATION='TESTED PHYSICAL OR EMERGENCY CONSOLE'
readonly KEYS_CONFIRMATION='TESTED BOTH APPROVED SSH KEYS'

mode=''
admin_user=''
approved_keys=''
office_cidr=''
vpn_cidr=''
expected_keyset_sha256=''
password_confirmation=''
console_confirmation=''
keys_confirmation=''
declare -a expected_key_fingerprints=()
declare -a actual_key_fingerprints=()
current_txid=''
keyset_sha256='';
office_representative=''
vpn_representative=''
ssh_client_ip=''
ssh_server_ip=''

die() {
  printf 'PHASE1B_REFUSED: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage -- stage the reviewed, root-owned key trust set without disabling passwords:
  sudo --preserve-env=SSH_CONNECTION bash phase1b-ssh-key-only.sh \
    --stage-keys \
    --admin-user ADMIN \
    --approved-keys /root/trusted-ssh/admin-authorized-keys \
    --expected-key-fingerprint 'SHA256:KEY_A_OUT_OF_BAND' \
    --expected-key-fingerprint 'SHA256:KEY_B_OUT_OF_BAND' \
    --office-cidr __EXACT_OFFICE_CIDR__ \
    --vpn-cidr __EXACT_VPN_CIDR__ \
    --confirm-password-rotated 'ROTATED DISCLOSED SERVER PASSWORD OUT OF BAND' \
    --confirm-physical-console 'TESTED PHYSICAL OR EMERGENCY CONSOLE'

Usage -- after both staged keys logged in independently, commit key-only SSH:
  sudo --preserve-env=SSH_CONNECTION bash phase1b-ssh-key-only.sh \
    --commit-key-only \
    --admin-user ADMIN \
    --approved-keys /root/trusted-ssh/admin-authorized-keys \
    --expected-keyset-sha256 REVIEWED_64_LOWERCASE_HEX_DIGEST \
    --office-cidr __EXACT_OFFICE_CIDR__ \
    --vpn-cidr __EXACT_VPN_CIDR__ \
    --confirm-password-rotated 'ROTATED DISCLOSED SERVER PASSWORD OUT OF BAND' \
    --confirm-physical-console 'TESTED PHYSICAL OR EMERGENCY CONSOLE' \
    --confirm-two-keys-tested 'TESTED BOTH APPROVED SSH KEYS'

Exactly one trust proof is required: either two distinct out-of-band SHA256 key
fingerprints, or one out-of-band SHA-256 digest of the exact approved-keys file.
The approved file must contain exactly two plain Ed25519/FIDO public-key lines,
must be root-owned through its complete path, and must not be writable by group
or others. The installed public key file is root:root 0644 because OpenSSH opens
AuthorizedKeysFile under the target UID; public keys are not secrets and remain
unmodifiable by that UID. Passwords must never be supplied to this script or placed in shell
history. The password-rotation confirmation is procedural evidence only: stop
unless the disclosed password was actually changed through a private channel.

The script refuses unreviewed Match/nested Include SSH configuration, any SSH
port other than 22, non-local or aliased administrator identities, additional
public-key authorities, and unsafe partial state. An interrupted transaction is
rolled back and reloaded on the next invocation; that recovery invocation exits
non-zero and must be followed by a fresh reviewed invocation. It only supports
Ubuntu 24.04 direct ssh.service mode with ssh.socket disabled and no service
drop-ins or dynamic firewall agents. Over SSH, run from a direct session (not
tmux or screen) and preserve the real SSH_CONNECTION through sudo.
EOF
}

need_value() {
  [[ "$#" -ge 2 ]] || die "missing value for $1"
}

set_mode() {
  [[ -z "$mode" ]] || die 'choose exactly one of --stage-keys or --commit-key-only'
  mode="$1"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --stage-keys) set_mode staged; shift ;;
    --commit-key-only) set_mode key-only; shift ;;
    --admin-user) need_value "$@"; admin_user="$2"; shift 2 ;;
    --approved-keys) need_value "$@"; approved_keys="$2"; shift 2 ;;
    --office-cidr) need_value "$@"; office_cidr="$2"; shift 2 ;;
    --vpn-cidr) need_value "$@"; vpn_cidr="$2"; shift 2 ;;
    --expected-keyset-sha256) need_value "$@"; expected_keyset_sha256="$2"; shift 2 ;;
    --expected-key-fingerprint)
      need_value "$@"
      expected_key_fingerprints+=("$2")
      shift 2
      ;;
    --confirm-password-rotated) need_value "$@"; password_confirmation="$2"; shift 2 ;;
    --confirm-physical-console) need_value "$@"; console_confirmation="$2"; shift 2 ;;
    --confirm-two-keys-tested) need_value "$@"; keys_confirmation="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die 'run as root'
[[ "$mode" == staged || "$mode" == key-only ]] || die 'choose --stage-keys or --commit-key-only'
[[ "$admin_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$admin_user" != root ]] \
  || die 'ADMIN must be a non-root local Linux account name'
[[ -n "$approved_keys" && -n "$office_cidr" && -n "$vpn_cidr" ]] \
  || die '--approved-keys, --office-cidr and --vpn-cidr are required'
[[ "$password_confirmation" == "$PASSWORD_CONFIRMATION" ]] \
  || die "--confirm-password-rotated must exactly equal: $PASSWORD_CONFIRMATION"
[[ "$console_confirmation" == "$CONSOLE_CONFIRMATION" ]] \
  || die "--confirm-physical-console must exactly equal: $CONSOLE_CONFIRMATION"
if [[ "$mode" == key-only ]]; then
  [[ "$keys_confirmation" == "$KEYS_CONFIRMATION" ]] \
    || die "--confirm-two-keys-tested must exactly equal: $KEYS_CONFIRMATION"
elif [[ -n "$keys_confirmation" ]]; then
  die '--confirm-two-keys-tested is only valid with --commit-key-only'
fi
if [[ -n "$expected_keyset_sha256" && "${#expected_key_fingerprints[@]}" -ne 0 ]]; then
  die 'use either --expected-keyset-sha256 or two --expected-key-fingerprint values, not both'
fi
if [[ -n "$expected_keyset_sha256" ]]; then
  [[ "$expected_keyset_sha256" =~ ^[0-9a-f]{64}$ ]] \
    || die '--expected-keyset-sha256 must be 64 lowercase hexadecimal characters'
else
  [[ "${#expected_key_fingerprints[@]}" -eq 2 ]] \
    || die 'exactly two --expected-key-fingerprint values are required without a keyset digest'
  [[ "${expected_key_fingerprints[0]}" != "${expected_key_fingerprints[1]}" ]] \
    || die 'the two expected SSH key fingerprints must be distinct'
  for fingerprint in "${expected_key_fingerprints[@]}"; do
    [[ "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] \
      || die "invalid SHA256 SSH key fingerprint: $fingerprint"
  done
fi

require_root_installer() {
  local source_file current source_mode
  [[ ! -L "${BASH_SOURCE[0]}" ]] || die 'refusing to execute SSH hardening through a symlink'
  source_file="$(realpath -e -- "${BASH_SOURCE[0]}")"
  [[ -f "$source_file" && "$(stat -c '%u:%h' -- "$source_file")" == 0:1 ]] \
    || die 'SSH hardening installer must be root-owned with one hard link'
  source_mode="$(stat -c '%a' -- "$source_file")"
  (( (8#$source_mode & 0022) == 0 )) || die 'SSH hardening installer must not be group/world writable'
  current="$(dirname -- "$source_file")"
  while :; do
    [[ -d "$current" && ! -L "$current" && "$(stat -c '%u' -- "$current")" == 0 ]] \
      || die "unsafe SSH hardening installer directory: $current"
    source_mode="$(stat -c '%a' -- "$current")"
    (( (8#$source_mode & 0022) == 0 )) || die "SSH hardening installer directory is writable: $current"
    [[ "$current" == / ]] && break
    current="$(dirname -- "$current")"
  done
}

require_root_installer
for required_command in realpath stat flock python3 ssh-keygen sha256sum md5sum cmp sshd systemctl ss ufw \
  dpkg dpkg-query iptables ip6tables iptables-save ip6tables-save nft; do
  command -v "$required_command" >/dev/null 2>&1 || die "required command is unavailable: $required_command"
done

[[ ! -L "$LOCK_PATH" ]] || die "unsafe lock symlink: $LOCK_PATH"
exec 9>"$LOCK_PATH"
chmod 0600 "$LOCK_PATH"
flock -n 9 || die 'another SSH hardening transaction is active'

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
  temporary="$(mktemp "$destination_dir/.uten-ssh-install.XXXXXX")" || return 1
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

root_directory_is_safe() {
  local directory="$1" directory_mode
  [[ -d "$directory" && ! -L "$directory" && "$(stat -c '%u' -- "$directory")" == 0 ]] || return 1
  directory_mode="$(stat -c '%a' -- "$directory")" || return 1
  (( (8#$directory_mode & 0022) == 0 )) || return 1
}

validate_root_directory() {
  root_directory_is_safe "$1" || die "unsafe or writable root directory: $1"
}

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

verify_phase1_ufw_user_checkpoint() {
  local candidate
  validate_root_regular_file /etc/ufw/user.rules 640
  validate_root_regular_file /etc/ufw/user6.rules 640
  validate_root_regular_file "$PHASE1_UFW_USER_RULES_SHA256" 600
  candidate="$(mktemp /run/uten-imp-phase1b-ufw-user.XXXXXX)" || return 1
  sha256sum -- /etc/ufw/user.rules /etc/ufw/user6.rules >"$candidate" || return 1
  if ! cmp -s -- "$candidate" "$PHASE1_UFW_USER_RULES_SHA256"; then
    rm -f -- "$candidate" >/dev/null 2>&1 || :
    return 1
  fi
  rm -f -- "$candidate" || return 1
}

capture_firewall_runtime() {
  local raw4="$1" raw6="$2" nft_rules="$3" nft_tables="$4"
  iptables-save | sed -e '/^# Generated by /d' -e '/^# Completed on /d' >"$raw4" || return 1
  ip6tables-save | sed -e '/^# Generated by /d' -e '/^# Completed on /d' >"$raw6" || return 1
  nft --stateless list ruleset >"$nft_rules" || return 1
  nft list tables | sort >"$nft_tables" || return 1
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
  raw4="$(mktemp /run/uten-imp-phase1b-runtime4.XXXXXX)" || return 1
  raw6="$(mktemp /run/uten-imp-phase1b-runtime6.XXXXXX)" || return 1
  nft_rules="$(mktemp /run/uten-imp-phase1b-runtime-nft.XXXXXX)" || return 1
  nft_tables="$(mktemp /run/uten-imp-phase1b-runtime-tables.XXXXXX)" || return 1
  capture_firewall_runtime "$raw4" "$raw6" "$nft_rules" "$nft_tables" || return 1
  validate_active_runtime_graph "$raw4" "$raw6" "$nft_tables" || return 1
  hash4="$(sha256sum -- "$raw4" | awk '{ print $1 }')" || return 1
  hash6="$(sha256sum -- "$raw6" | awk '{ print $1 }')" || return 1
  nft_hash="$(sha256sum -- "$nft_rules" | awk '{ print $1 }')" || return 1
  printf 'iptables_sha256=%s\nip6tables_sha256=%s\nnft_stateless_sha256=%s\n' \
    "$hash4" "$hash6" "$nft_hash" >"$destination" || return 1
  rm -f -- "$raw4" "$raw6" "$nft_rules" "$nft_tables" || return 1
}

verify_phase1_runtime_checkpoint() {
  local candidate
  validate_root_regular_file "$PHASE1_UFW_RUNTIME_SHA256" 600
  candidate="$(mktemp /run/uten-imp-phase1b-runtime-sha.XXXXXX)" || return 1
  render_runtime_checkpoint "$candidate" || return 1
  if ! cmp -s -- "$candidate" "$PHASE1_UFW_RUNTIME_SHA256"; then
    rm -f -- "$candidate" >/dev/null 2>&1 || :
    return 1
  fi
  rm -f -- "$candidate" || return 1
}

verify_final_ufw_conf() {
  local candidate
  validate_root_regular_file /etc/ufw/ufw.conf 644
  [[ "$(grep -Ec '^ENABLED=' /usr/share/ufw/ufw.conf)" == 1 \
    && "$(grep -Ec '^LOGLEVEL=' /usr/share/ufw/ufw.conf)" == 1 ]] \
    || die 'the installed ufw.conf skeleton is not auditable'
  candidate="$(mktemp /run/uten-imp-phase1b-ufw-conf.XXXXXX)"
  sed -e 's/^ENABLED=.*/ENABLED=yes/' -e 's/^LOGLEVEL=.*/LOGLEVEL=medium/' \
    /usr/share/ufw/ufw.conf >"$candidate"
  cmp -s -- "$candidate" /etc/ufw/ufw.conf || {
    rm -f -- "$candidate"
    die '/etc/ufw/ufw.conf differs from the exact enabled/medium package-derived contract'
  }
  rm -f -- "$candidate"
}

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
if [[ -e "$TRANSACTION_ROOT" || -L "$TRANSACTION_ROOT" ]]; then
  validate_root_directory "$TRANSACTION_ROOT"
fi
install -d -o 0 -g 0 -m 0700 "$TRANSACTION_ROOT"
validate_root_directory "$TRANSACTION_ROOT"
fsync_path "$STATE_DIR"
fsync_path "$TRANSACTION_ROOT"

validate_root_file_chain() {
  local file_path="$1" current file_mode
  [[ ! -L "$file_path" ]] || die "trusted file may not be a symlink: $file_path"
  file_path="$(realpath -e -- "$file_path")"
  [[ -f "$file_path" && "$(stat -c '%u:%h' -- "$file_path")" == 0:1 ]] \
    || die "trusted file must be root-owned with one hard link: $file_path"
  file_mode="$(stat -c '%a' -- "$file_path")"
  (( (8#$file_mode & 0022) == 0 )) || die "trusted file is group/world writable: $file_path"
  current="$(dirname -- "$file_path")"
  while :; do
    validate_root_directory "$current"
    [[ "$current" == / ]] && break
    current="$(dirname -- "$current")"
  done
  printf '%s\n' "$file_path"
}

validate_managed_destination() {
  local destination="$1" expected_owner="$2" allowed_mode_regex="$3" metadata
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" ]] || die "managed destination is not a regular file: $destination"
    metadata="$(stat -c '%u:%g:%a:%h' -- "$destination")"
    [[ "$metadata" =~ ^${expected_owner}:${allowed_mode_regex}:1$ ]] \
      || die "unsafe managed destination metadata: $destination ($metadata)"
  fi
}

validate_admin_identity() {
  local passwd_row passwd_count uid gid home shell nss_count group_row group_count primary_group
  local primary_gid_count primary_nss_count sudo_row sudo_count sudo_gid sudo_gid_count sudo_nss_count home_mode parent
  passwd_count="$(awk -F: -v user="$admin_user" '$1 == user { count++ } END { print count + 0 }' /etc/passwd)"
  [[ "$passwd_count" == 1 ]] || die "$admin_user must have exactly one local /etc/passwd row"
  passwd_row="$(awk -F: -v user="$admin_user" '$1 == user { print }' /etc/passwd)"
  IFS=: read -r _ _ uid gid _ home shell <<<"$passwd_row"
  [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || die 'administrator UID/GID must be numeric'
  (( uid >= 1000 && uid < 65534 )) || die 'administrator UID must be a non-system, non-nobody identity'
  nss_count="$(getent passwd | awk -F: -v id="$uid" '$3 == id { count++ } END { print count + 0 }')"
  [[ "$nss_count" == 1 ]] || die "administrator numeric UID $uid is aliased in NSS"
  [[ "$(getent passwd "$admin_user")" == "$passwd_row" ]] \
    || die 'NSS administrator identity differs from the local /etc/passwd identity'

  group_count="$(awk -F: -v id="$gid" '$3 == id { count++ } END { print count + 0 }' /etc/group)"
  [[ "$group_count" == 1 ]] || die "administrator primary GID $gid must have exactly one local group name"
  primary_nss_count="$(getent group | awk -F: -v id="$gid" '$3 == id { count++ } END { print count + 0 }')"
  [[ "$primary_nss_count" == 1 ]] || die "administrator primary GID $gid is aliased in NSS"
  group_row="$(awk -F: -v id="$gid" '$3 == id { print }' /etc/group)"
  IFS=: read -r primary_group _ _ primary_members <<<"$group_row"
  [[ "$primary_group" == "$admin_user" && -z "$primary_members" ]] \
    || die 'administrator must use an empty user-private primary group with the same name'
  primary_gid_count="$(awk -F: -v id="$gid" '$4 == id { count++ } END { print count + 0 }' /etc/passwd)"
  [[ "$primary_gid_count" == 1 ]] || die 'administrator primary GID is shared by another local account'

  sudo_count="$(awk -F: '$1 == "sudo" { count++ } END { print count + 0 }' /etc/group)"
  [[ "$sudo_count" == 1 ]] || die 'local sudo group must have exactly one /etc/group row'
  sudo_row="$(awk -F: '$1 == "sudo" { print }' /etc/group)"
  IFS=: read -r _ _ sudo_gid _ <<<"$sudo_row"
  sudo_gid_count="$(awk -F: -v id="$sudo_gid" '$3 == id { count++ } END { print count + 0 }' /etc/group)"
  [[ "$sudo_gid_count" == 1 ]] || die "sudo numeric GID $sudo_gid has a group-name alias"
  sudo_nss_count="$(getent group | awk -F: -v id="$sudo_gid" '$3 == id { count++ } END { print count + 0 }')"
  [[ "$sudo_nss_count" == 1 ]] || die "sudo numeric GID $sudo_gid is aliased in NSS"
  id -G "$admin_user" | tr ' ' '\n' | grep -Fxq "$sudo_gid" \
    || die "$admin_user is not a numeric member of the local sudo group"

  [[ "$home" == /* && "$home" != / && -d "$home" && ! -L "$home" ]] \
    || die 'administrator home must be an existing absolute non-symlink directory'
  [[ "$(realpath -e -- "$home")" == "$home" ]] || die 'administrator home path must be canonical'
  [[ "$(stat -c '%u:%g' -- "$home")" == "$uid:$gid" ]] \
    || die 'administrator home numeric owner differs from the approved identity'
  home_mode="$(stat -c '%a' -- "$home")"
  (( (8#$home_mode & 0022) == 0 )) || die 'administrator home must not be group/world writable'
  parent="$(dirname -- "$home")"
  while :; do
    validate_root_directory "$parent"
    [[ "$parent" == / ]] && break
    parent="$(dirname -- "$parent")"
  done
  [[ "$shell" == /* && -x "$shell" && "$shell" != */nologin && "$shell" != */false ]] \
    || die 'administrator must have an approved interactive shell'
}

audit_sshd_config_tree() {
  local main=/etc/ssh/sshd_config file file_mode include_count other_include_count match_count
  local -a fragments=()
  [[ -f "$main" && ! -L "$main" && "$(stat -c '%u:%g:%h' -- "$main")" == 0:0:1 ]] \
    || die '/etc/ssh/sshd_config must be root-owned, regular and single-linked'
  file_mode="$(stat -c '%a' -- "$main")"
  (( (8#$file_mode & 0022) == 0 )) || die '/etc/ssh/sshd_config is group/world writable'
  validate_root_directory /etc
  validate_root_directory /etc/ssh
  validate_root_directory "$CONFIG_DIR"

  include_count="$(awk '
    { line=$0; sub(/^[[:space:]]*/, "", line) }
    line == "" || substr(line,1,1) == "#" { next }
    { normalized=tolower(line); gsub(/[[:space:]]+/, " ", normalized) }
    normalized == "include /etc/ssh/sshd_config.d/*.conf" { count++ }
    END { print count + 0 }
  ' "$main")"
  other_include_count="$(awk '
    { line=$0; sub(/^[[:space:]]*/, "", line) }
    line == "" || substr(line,1,1) == "#" { next }
    { normalized=tolower(line); gsub(/[[:space:]]+/, " ", normalized) }
    normalized ~ /^include[[:space:]]/ && normalized != "include /etc/ssh/sshd_config.d/*.conf" { count++ }
    END { print count + 0 }
  ' "$main")"
  [[ "$include_count" == 1 && "$other_include_count" == 0 ]] \
    || die 'sshd_config must contain exactly one canonical Include and no other Include directives'

  shopt -s nullglob
  fragments=("$CONFIG_DIR"/*.conf)
  shopt -u nullglob
  for file in "$main" "${fragments[@]}"; do
    [[ -f "$file" && ! -L "$file" && "$(stat -c '%u:%g:%h' -- "$file")" == 0:0:1 ]] \
      || die "unsafe SSH configuration fragment: $file"
    file_mode="$(stat -c '%a' -- "$file")"
    (( (8#$file_mode & 0022) == 0 )) || die "SSH configuration fragment is writable: $file"
    match_count="$(awk '
      { line=$0; sub(/^[[:space:]]*/, "", line) }
      line == "" || substr(line,1,1) == "#" { next }
      { split(line, fields, /[[:space:]]+/) }
      tolower(fields[1]) == "match" { count++ }
      END { print count + 0 }
    ' "$file")"
    [[ "$match_count" == 0 ]] || die "unreviewed Match directive is forbidden: $file"
    if [[ "$file" != "$main" ]] && awk '
      { line=$0; sub(/^[[:space:]]*/, "", line) }
      line == "" || substr(line,1,1) == "#" { next }
      { split(line, fields, /[[:space:]]+/) }
      tolower(fields[1]) == "include" { found=1 }
      END { exit(found ? 0 : 1) }
    ' "$file"; then
      die "nested Include directive is forbidden: $file"
    fi
  done
}

validate_admin_identity
validate_root_directory /etc
validate_root_directory /etc/ssh
if [[ -e "$CONFIG_DIR" || -L "$CONFIG_DIR" ]]; then
  validate_root_directory "$CONFIG_DIR"
fi
install -d -o 0 -g 0 -m 0755 "$CONFIG_DIR"
validate_root_directory "$CONFIG_DIR"
fsync_path /etc/ssh
if [[ -e "$AUTHORIZED_KEYS_DIR" || -L "$AUTHORIZED_KEYS_DIR" ]]; then
  validate_root_directory "$AUTHORIZED_KEYS_DIR"
fi
install -d -o 0 -g 0 -m 0755 "$AUTHORIZED_KEYS_DIR"
validate_root_directory "$AUTHORIZED_KEYS_DIR"
fsync_path /etc/ssh
fsync_path "$CONFIG_DIR"
fsync_path "$AUTHORIZED_KEYS_DIR"
validate_managed_destination "$CONFIG_PATH" 0:0 '[0-7]{3,4}'
readonly AUTHORIZED_KEYS_PATH="$AUTHORIZED_KEYS_DIR/$admin_user"
validate_managed_destination "$AUTHORIZED_KEYS_PATH" 0:0 '644'
audit_sshd_config_tree

approved_keys="$(validate_root_file_chain "$approved_keys")"
[[ "$approved_keys" != "$AUTHORIZED_KEYS_PATH" ]] || die 'approved key source must be separate from the managed destination'
awk '
  BEGIN { ok=1; count=0 }
  /^[[:space:]]*$/ { ok=0; next }
  /^[[:space:]]*#/ { ok=0; next }
  {
    count++
    if (($1 != "ssh-ed25519" && $1 != "sk-ssh-ed25519@openssh.com") || NF < 2) ok=0
  }
  END { exit(ok && count == 2 ? 0 : 1) }
' "$approved_keys" \
  || die 'approved key file must contain exactly two plain Ed25519/FIDO public-key lines and nothing else'

mapfile -t key_records < <(awk '{ print $1 " " $2 }' "$approved_keys")
for key_record in "${key_records[@]}"; do
  key_probe="$(mktemp /run/uten-imp-approved-key.XXXXXX)"
  printf '%s\n' "$key_record" >"$key_probe"
  key_fingerprint="$(ssh-keygen -l -E sha256 -f "$key_probe" 2>/dev/null | awk 'NR == 1 { print $2 }')"
  rm -f -- "$key_probe"
  [[ "$key_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] \
    || die 'approved key file contains an invalid Ed25519/FIDO public key'
  actual_key_fingerprints+=("$key_fingerprint")
done
[[ "${actual_key_fingerprints[0]}" != "${actual_key_fingerprints[1]}" ]] \
  || die 'approved key file contains the same public key twice'
keyset_sha256="$(sha256sum -- "$approved_keys" | awk '{ print $1 }')"
if [[ -n "$expected_keyset_sha256" ]]; then
  [[ "$keyset_sha256" == "$expected_keyset_sha256" ]] || die 'approved keyset SHA-256 differs from the out-of-band digest'
else
  actual_sorted="$(printf '%s\n' "${actual_key_fingerprints[@]}" | sort)"
  expected_sorted="$(printf '%s\n' "${expected_key_fingerprints[@]}" | sort)"
  [[ "$actual_sorted" == "$expected_sorted" ]] || die 'approved SSH key fingerprints differ from the two out-of-band fingerprints'
  unset actual_sorted expected_sorted
fi

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
    || die 'the current SSH connection is not using the approved server port 22'
fi

if [[ -n "${SSH_CONNECTION:-}" ]]; then
  verify_ssh_connection_socket "${ssh_connection_fields[0]}" "${ssh_connection_fields[1]}" \
    "${ssh_connection_fields[2]}" "${ssh_connection_fields[3]}" "$ssh_ancestor_pids" \
    || die 'SSH_CONNECTION is not the current kernel TCP/22 session owned by an sshd ancestor'
fi

mapfile -t cidr_validation < <(/usr/bin/python3 -I - "$office_cidr" "$vpn_cidr" "$ssh_client_ip" "$ssh_server_ip" <<'PY'
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
        raise SystemExit("current SSH client is outside both approved CIDRs")
    if server.is_multicast or server.is_unspecified:
        raise SystemExit("SSH_CONNECTION contains an unsafe server address")
for network in networks:
    representative = network.network_address if network.num_addresses == 1 else network.network_address + 1
    print(representative)
PY
)
[[ "${#cidr_validation[@]}" -eq 2 ]] || die 'CIDR validation did not return two representative addresses'
office_representative="${cidr_validation[0]}"
vpn_representative="${cidr_validation[1]}"

verify_phase1_firewall_contract() {
  local request_candidate rules_candidate current_candidate raw approved_cidr
  root_directory_is_safe "$PHASE1_FIREWALL_DIR" \
    || die 'Phase1 firewall state directory is missing or unsafe'
  [[ "$(stat -c '%u:%g:%a:%h' -- "$PHASE1_FIREWALL_DIR")" == 0:0:700:1 ]] \
    || die 'Phase1 firewall state directory metadata differs from the audited contract'
  [[ ! -e "$PHASE1_FIREWALL_IN_PROGRESS" && ! -L "$PHASE1_FIREWALL_IN_PROGRESS" ]] \
    || die 'Phase1 firewall transaction is still in progress; SSH authentication change is NO-GO'
  validate_root_regular_file "$PHASE1_FIREWALL_COMPLETE" 600
  validate_root_regular_file "$PHASE1_FIREWALL_EXPECTED_RULES" 600
  verify_ufw_framework_baseline

  request_candidate="$(mktemp /run/uten-imp-phase1b-fw-state.XXXXXX)"
  printf 'office_cidr=%s\nvpn_cidr=%s\nssh_port=%s\n' \
    "$office_cidr" "$vpn_cidr" "$SSH_PORT" >"$request_candidate"
  cmp -s -- "$request_candidate" "$PHASE1_FIREWALL_COMPLETE" || {
    rm -f -- "$request_candidate"
    die 'Phase1 firewall COMPLETE identity differs from this SSH request'
  }
  rm -f -- "$request_candidate"

  rules_candidate="$(mktemp /run/uten-imp-phase1b-fw-rules.XXXXXX)"
  for approved_cidr in "$office_cidr" "$vpn_cidr"; do
    printf "ufw allow from %s to any port 22 proto tcp comment 'uten-admin-ssh'\n" "$approved_cidr"
    printf "ufw allow from %s to any port 80 proto tcp comment 'uten-http-redirect'\n" "$approved_cidr"
    printf "ufw allow from %s to any port 443 proto tcp comment 'uten-erp-https'\n" "$approved_cidr"
  done | sort >"$rules_candidate"
  cmp -s -- "$rules_candidate" "$PHASE1_FIREWALL_EXPECTED_RULES" || {
    rm -f -- "$rules_candidate"
    die 'Phase1 firewall EXPECTED_RULES differ from this SSH request'
  }
  current_candidate="$(mktemp /run/uten-imp-phase1b-fw-current.XXXXXX)"
  ufw show added 2>/dev/null | sed -n '/^ufw[[:space:]]/p' | sort >"$current_candidate"
  cmp -s -- "$current_candidate" "$rules_candidate" || {
    rm -f -- "$rules_candidate" "$current_candidate"
    die 'live UFW added rules differ from Phase1 exact office/VPN rules'
  }
  rm -f -- "$rules_candidate" "$current_candidate"

  verify_phase1_ufw_user_checkpoint \
    || die 'live UFW user-rule files differ from the Phase1 durable checkpoint'
  verify_final_ufw_conf
  [[ "$(ufw status | sed -n '1p')" == 'Status: active' ]] \
    || die 'Phase1 UFW is not active'
  ufw status verbose | grep -Eq 'Default:[[:space:]]+deny \(incoming\), allow \(outgoing\)' \
    || die 'Phase1 UFW defaults differ from deny-incoming/allow-outgoing'
  systemctl is-active --quiet ufw.service || die 'ufw.service is not active'
  [[ "$(systemctl is-enabled ufw.service)" == enabled ]] || die 'ufw.service is not enabled for boot'
  raw="$(ufw show raw)"
  awk '
    /^IPV4 \(raw\):/ { family="v4"; next }
    /^IPV6 \(raw\):/ { family="v6"; next }
    family == "v4" && /^Chain INPUT \(policy DROP([[:space:]]|\))/ { v4=1 }
    family == "v6" && /^Chain INPUT \(policy DROP([[:space:]]|\))/ { v6=1 }
    END { exit(v4 && v6 ? 0 : 1) }
  ' <<<"$raw" || die 'Phase1 live IPv4/IPv6 INPUT policies are not both DROP'
  verify_phase1_runtime_checkpoint \
    || die 'live IPv4/IPv6/nft firewall runtime differs from Phase1 durable evidence'
}

verify_live_ssh_runtime_contract() {
  local main_pid control_group listeners_file
  /usr/sbin/sshd -t || return 1
  systemctl is-active --quiet ssh.service || return 1
  main_pid="$(systemctl show -p MainPID --value ssh.service)" || return 1
  [[ "$main_pid" =~ ^[0-9]+$ ]] || return 1
  (( main_pid > 1 )) || return 1
  control_group="$(systemctl show -p ControlGroup --value ssh.service)" || return 1
  [[ "$control_group" == /system.slice/ssh.service ]] || return 1
  /usr/bin/python3 -I - "$main_pid" "$control_group" <<'PY' || return 1
import os
import pathlib
import re
import sys

pid, expected_cgroup = sys.argv[1:]
proc = pathlib.Path("/proc") / pid
if os.path.realpath(proc / "exe") != "/usr/sbin/sshd":
    raise SystemExit("ssh.service MainPID executable is not /usr/sbin/sshd")
argv = [part.decode("utf-8", "strict") for part in (proc / "cmdline").read_bytes().split(b"\0") if part]
direct = argv == ["/usr/sbin/sshd", "-D"]
listener_title = len(argv) == 1 and re.fullmatch(
    r"sshd: /usr/sbin/sshd -D \[listener\](?: [0-9]+ of [0-9]+-[0-9]+ startups)?", argv[0]
)
if not (direct or listener_title):
    raise SystemExit(f"ssh.service MainPID has unaudited argv: {argv!r}")
environment = {}
for item in (proc / "environ").read_bytes().split(b"\0"):
    if not item or b"=" not in item:
        continue
    key, value = item.split(b"=", 1)
    environment[key] = value
if environment.get(b"SSHD_OPTS", b"") != b"":
    raise SystemExit("live ssh.service has non-empty SSHD_OPTS")
status = (proc / "status").read_text(encoding="utf-8")
if not re.search(r"^Uid:\s+0\s+0\s+0\s+0$", status, re.MULTILINE):
    raise SystemExit("ssh.service MainPID is not numeric UID 0")
if not re.search(r"^Gid:\s+0\s+0\s+0\s+0$", status, re.MULTILINE):
    raise SystemExit("ssh.service MainPID is not numeric GID 0")
cgroups = (proc / "cgroup").read_text(encoding="utf-8").splitlines()
if f"0::{expected_cgroup}" not in cgroups:
    raise SystemExit("ssh.service MainPID is outside its exact cgroup")
PY
  listeners_file="$(mktemp /run/uten-imp-sshd-listeners.XXXXXX)" || return 1
  ss -H -ltnp >"$listeners_file" || return 1
  /usr/bin/python3 -I - "$listeners_file" "$main_pid" "$SSH_PORT" <<'PY' || return 1
import pathlib
import re
import sys

path, expected_pid, expected_port = sys.argv[1:]
sshd_listeners = 0
approved_port_listeners = 0
for raw in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
    fields = raw.split()
    if len(fields) < 5:
        raise SystemExit(f"unparseable ss listener row: {raw}")
    local_endpoint = fields[3]
    port = local_endpoint.rsplit(":", 1)[-1]
    process_text = " ".join(fields[5:]) if len(fields) > 5 else ""
    is_sshd = '"sshd"' in process_text
    is_approved_port = port == expected_port
    pids = set(re.findall(r"pid=([0-9]+)", process_text))
    if is_sshd:
        sshd_listeners += 1
        if not is_approved_port or pids != {expected_pid}:
            raise SystemExit(f"foreign sshd listener: {raw}")
    if is_approved_port:
        approved_port_listeners += 1
        if not is_sshd or pids != {expected_pid}:
            raise SystemExit(f"TCP/{expected_port} is not owned only by ssh.service MainPID: {raw}")
if sshd_listeners < 1 or approved_port_listeners < 1:
    raise SystemExit("no approved ssh.service listener exists")
PY
  rm -f -- "$listeners_file" || return 1
}

verify_ssh_service_contract() {
  local package_status package_verify_output fragment_path fragment_real dropins environment_files
  local unit_environment manager_opts socket_enabled active_socket_rows
  package_status="$(dpkg-query -W -f='${db:Status-Status}' openssh-server 2>/dev/null)"
  [[ "$package_status" == installed ]] || die 'openssh-server package is not fully installed'
  package_verify_output="$(dpkg --verify openssh-server 2>&1)" \
    || die 'dpkg could not verify openssh-server'
  [[ -z "$package_verify_output" ]] \
    || die 'openssh-server package or conffile bytes differ from dpkg-recorded bytes; independent review is required'

  fragment_path="$(systemctl show -p FragmentPath --value ssh.service)"
  [[ "$fragment_path" == /usr/lib/systemd/system/ssh.service ]] \
    || die "ssh.service has an unaudited FragmentPath: $fragment_path"
  fragment_real="$(realpath -e -- "$fragment_path")"
  [[ "$fragment_real" == /usr/lib/systemd/system/ssh.service ]] \
    || die 'ssh.service fragment does not resolve to the Ubuntu package path'
  validate_root_directory /usr
  validate_root_directory /usr/lib
  validate_root_directory /usr/lib/systemd
  validate_root_directory /usr/lib/systemd/system
  validate_root_directory /etc
  validate_root_directory /etc/default
  validate_root_regular_file "$fragment_real" 644
  dropins="$(systemctl show -p DropInPaths --value ssh.service)"
  [[ -z "$dropins" ]] || die "ssh.service drop-ins are forbidden in audited service mode: $dropins"
  [[ "$(systemctl show -p NeedDaemonReload --value ssh.service)" == no ]] \
    || die 'systemd has unapplied ssh.service changes'
  [[ "$(systemctl show -p Transient --value ssh.service)" == no ]] \
    || die 'transient ssh.service units are forbidden'
  [[ "$(systemctl show -p LoadState --value ssh.service)" == loaded ]] \
    || die 'ssh.service is not loaded from disk'

  [[ "$(grep -Fxc 'EnvironmentFile=-/etc/default/ssh' "$fragment_real")" == 1 \
    && "$(grep -Ec '^EnvironmentFile=' "$fragment_real")" == 1 ]] \
    || die 'ssh.service must use only the audited /etc/default/ssh EnvironmentFile'
  [[ "$(grep -Fxc 'ExecStartPre=/usr/sbin/sshd -t' "$fragment_real")" == 1 \
    && "$(grep -Ec '^ExecStartPre=' "$fragment_real")" == 1 ]] \
    || die 'ssh.service ExecStartPre differs from the audited syntax check'
  [[ "$(grep -Fxc 'ExecStart=/usr/sbin/sshd -D $SSHD_OPTS' "$fragment_real")" == 1 \
    && "$(grep -Ec '^ExecStart=' "$fragment_real")" == 1 ]] \
    || die 'ssh.service ExecStart differs from /usr/sbin/sshd -D $SSHD_OPTS'
  [[ "$(grep -Fxc 'ExecReload=/usr/sbin/sshd -t' "$fragment_real")" == 1 \
    && "$(grep -Fxc 'ExecReload=/bin/kill -HUP $MAINPID' "$fragment_real")" == 1 \
    && "$(grep -Ec '^ExecReload=' "$fragment_real")" == 2 ]] \
    || die 'ssh.service reload must validate default sshd_config before HUP'
  [[ "$(grep -Ec '^Environment=' "$fragment_real")" == 0 ]] \
    || die 'ssh.service contains an unaudited inline environment'

  validate_root_regular_file /etc/default/ssh 644
  [[ "$(awk '
    { line=$0; sub(/^[[:space:]]*/, "", line) }
    line == "" || substr(line,1,1) == "#" { next }
    line == "SSHD_OPTS=" { approved++ ; next }
    { rejected++ }
    END { print (approved == 1 && rejected == 0) ? "yes" : "no" }
  ' /etc/default/ssh)" == yes ]] \
    || die '/etc/default/ssh must contain exactly one empty SSHD_OPTS assignment and no other active bytes'
  environment_files="$(systemctl show -p EnvironmentFiles --value ssh.service)"
  [[ "$environment_files" == '/etc/default/ssh (ignore_errors=yes)' ]] \
    || die "ssh.service runtime EnvironmentFiles differ from the audited contract: $environment_files"
  unit_environment="$(systemctl show -p Environment --value ssh.service)"
  /usr/bin/python3 -I - "$unit_environment" <<'PY' \
    || die 'ssh.service has a non-empty unit-level SSHD_OPTS override'
import shlex
import sys
for item in shlex.split(sys.argv[1]):
    if item.startswith("SSHD_OPTS=") and item != "SSHD_OPTS=":
        raise SystemExit(1)
PY
  manager_opts="$(systemctl show-environment | awk -F= '$1 == "SSHD_OPTS" { count++; value=substr($0, index($0, "=") + 1) } END { if (count) print count ":" value }')"
  [[ -z "$manager_opts" || "$manager_opts" == 1: ]] \
    || die 'systemd manager has a non-empty or duplicate SSHD_OPTS override'

  systemctl is-active --quiet ssh.service || die 'ssh.service is not active'
  [[ "$(systemctl is-enabled ssh.service)" == enabled ]] \
    || die 'ssh.service is not enabled for boot in audited service mode'
  systemctl is-active --quiet ssh.socket && die 'ssh.socket is active; migrate to audited ssh.service mode first'
  socket_enabled="$(systemctl is-enabled ssh.socket 2>/dev/null || true)"
  case "$socket_enabled" in
    disabled|masked|not-found|'') ;;
    *) die "ssh.socket is enabled or activatable: $socket_enabled" ;;
  esac
  active_socket_rows="$(systemctl list-sockets --no-legend --no-pager | awk '$0 ~ /(^|[[:space:]])ssh[^[:space:]]*\.socket([[:space:]]|$)/ { print }')"
  [[ -z "$active_socket_rows" ]] || die 'an SSH-related systemd socket is active'
  verify_live_ssh_runtime_contract \
    || die 'live ssh.service MainPID, argv, cgroup, numeric identity or listeners differ from the audited contract'
}

verify_ssh_port() {
  local configured_ports
  verify_ssh_service_contract
  configured_ports="$(/usr/sbin/sshd -T | awk '$1 == "port" { print $2 }')"
  [[ "$configured_ports" == "$SSH_PORT" ]] || die 'effective sshd configuration must expose exactly port 22'
}

verify_ssh_port

write_contexts() {
  local destination="$1" representative local_address
  : >"$destination" || return 1
  if [[ -n "$ssh_client_ip" ]]; then
    printf 'current|%s|%s|%s\n' "$ssh_client_ip" "$ssh_server_ip" "$SSH_PORT" >>"$destination" || return 1
  fi
  for representative in "$office_representative" "$vpn_representative"; do
    if [[ "$representative" == *:* ]]; then
      local_address='::1'
    else
      local_address='127.0.0.1'
    fi
    printf 'approved|%s|%s|%s\n' "$representative" "$local_address" "$SSH_PORT" >>"$destination" || return 1
  done
  fsync_path "$destination" || return 1
}

capture_effective() {
  local contexts_file="$1" output_file="$2" context_label remote_address local_address local_port context_user
  : >"$output_file" || return 1
  while IFS='|' read -r context_label remote_address local_address local_port; do
    [[ "$context_label" == current || "$context_label" == approved ]] || return 1
    [[ "$local_port" == "$SSH_PORT" ]] || return 1
    for context_user in "$admin_user" root; do
      printf 'CONTEXT %s %s %s %s %s\n' "$context_label" "$context_user" "$remote_address" "$local_address" "$local_port" >>"$output_file" \
        || return 1
      /usr/sbin/sshd -T -C "user=$context_user,host=$remote_address,addr=$remote_address,laddr=$local_address,lport=$local_port" \
        >>"$output_file" || return 1
    done
  done <"$contexts_file"
  fsync_path "$output_file" || return 1
}

assert_effective_line() {
  local effective_text="$1" expected_line="$2"
  grep -Fxq "$expected_line" <<<"$effective_text" || die "effective sshd contract missing: $expected_line"
}

validate_desired_effective() {
  local desired_mode="$1" contexts_file="$2"
  local context_label remote_address local_address local_port context_user effective_text configured_ports
  /usr/sbin/sshd -t
  audit_sshd_config_tree
  while IFS='|' read -r context_label remote_address local_address local_port; do
    for context_user in "$admin_user" root; do
      effective_text="$(/usr/sbin/sshd -T -C "user=$context_user,host=$remote_address,addr=$remote_address,laddr=$local_address,lport=$local_port")"
      configured_ports="$(awk '$1 == "port" { print $2 }' <<<"$effective_text")"
      [[ "$configured_ports" == "$SSH_PORT" ]] || die "effective SSH port differs in $context_label/$context_user context"
      assert_effective_line "$effective_text" 'permitrootlogin no'
      assert_effective_line "$effective_text" 'pubkeyauthentication yes'
      assert_effective_line "$effective_text" "authorizedkeysfile $AUTHORIZED_KEYS_PATH"
      assert_effective_line "$effective_text" 'authorizedkeyscommand none'
      assert_effective_line "$effective_text" 'trustedusercakeys none'
      assert_effective_line "$effective_text" 'strictmodes yes'
      assert_effective_line "$effective_text" "allowusers $admin_user"
      if grep -Eq '^(denyusers|denygroups|allowgroups)[[:space:]]' <<<"$effective_text"; then
        die "effective SSH user/group admission has an unmanaged deny/allow-group rule in $context_label/$context_user"
      fi
      assert_effective_line "$effective_text" 'x11forwarding no'
      assert_effective_line "$effective_text" 'allowtcpforwarding no'
      assert_effective_line "$effective_text" 'allowagentforwarding no'
      if [[ "$desired_mode" == key-only ]]; then
        assert_effective_line "$effective_text" 'passwordauthentication no'
        assert_effective_line "$effective_text" 'kbdinteractiveauthentication no'
        assert_effective_line "$effective_text" 'authenticationmethods publickey'
      fi
    done
  done <"$contexts_file"
}

state_value() {
  local state_file="$1" key="$2" count value
  [[ -f "$state_file" && ! -L "$state_file" && "$(stat -c '%u:%g:%a:%h' -- "$state_file")" == 0:0:600:1 ]] \
    || return 1
  count="$(grep -Ec "^${key}=" "$state_file")"
  [[ "$count" == 1 ]] || return 1
  value="$(sed -n "s/^${key}=//p" "$state_file")"
  [[ "$value" != *$'\n'* && -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

restore_transaction_file() {
  local transaction_dir="$1" label="$2" destination="$3"
  local restored_mode expected_hash preimage_hash restored_hash restored_metadata evidence_path
  if [[ -f "$transaction_dir/had-$label" && ! -L "$transaction_dir/had-$label" ]]; then
    [[ ! -e "$transaction_dir/absent-$label" && ! -L "$transaction_dir/absent-$label" ]] || return 1
    for evidence_path in "$transaction_dir/had-$label" "$transaction_dir/old-$label" \
      "$transaction_dir/$label-mode" "$transaction_dir/$label-sha256"; do
      [[ -f "$evidence_path" && ! -L "$evidence_path" \
        && "$(stat -c '%u:%g:%a:%h' -- "$evidence_path")" == 0:0:600:1 ]] || return 1
    done
    restored_mode="$(<"$transaction_dir/$label-mode")" || return 1
    expected_hash="$(<"$transaction_dir/$label-sha256")" || return 1
    [[ "$restored_mode" =~ ^[0-7]{3,4}$ && "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    (( (8#$restored_mode & 0022) == 0 )) || return 1
    preimage_hash="$(sha256sum -- "$transaction_dir/old-$label" | awk '{ print $1 }')" || return 1
    [[ "$preimage_hash" == "$expected_hash" ]] || return 1
    atomic_install "$transaction_dir/old-$label" "$destination" 0 0 "$restored_mode" || return 1
    [[ -f "$destination" && ! -L "$destination" ]] || return 1
    restored_metadata="$(stat -c '%u:%g:%a:%h' -- "$destination")" || return 1
    [[ "$restored_metadata" == "0:0:$restored_mode:1" ]] || return 1
    restored_hash="$(sha256sum -- "$destination" | awk '{ print $1 }')" || return 1
    [[ "$restored_hash" == "$expected_hash" ]] || return 1
  elif [[ -f "$transaction_dir/absent-$label" && ! -L "$transaction_dir/absent-$label" ]]; then
    [[ ! -e "$transaction_dir/had-$label" && ! -L "$transaction_dir/had-$label" ]] || return 1
    [[ "$(stat -c '%u:%g:%a:%h' -- "$transaction_dir/absent-$label")" == 0:0:600:1 ]] || return 1
    atomic_remove "$destination" || return 1
    [[ ! -e "$destination" && ! -L "$destination" ]] || return 1
  else
    printf 'PHASE1B_ROLLBACK_FAILED: missing %s preimage marker\n' "$label" >&2
    return 1
  fi
  return 0
}

rollback_transaction() {
  local txid="$1" transaction_dir="$TRANSACTION_ROOT/$txid" saved_admin before_hash rollback_effective rollback_hash
  [[ "$txid" =~ ^[0-9]{14}-[0-9]+$ ]] || return 1
  root_directory_is_safe "$transaction_dir" || return 1
  [[ "$(stat -c '%u:%g:%a:%h' -- "$transaction_dir")" == 0:0:700:1 ]] || return 1
  saved_admin="$(state_value "$transaction_dir/metadata" admin)" || return 1
  [[ "$saved_admin" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
  admin_user="$saved_admin"
  restore_transaction_file "$transaction_dir" config "$CONFIG_PATH" || return 1
  # Restore and activate the pre-transaction authentication policy before
  # removing or replacing any currently approved key. At every power-loss
  # boundary, disk boot state is therefore recoverable and the live daemon
  # still has either the new approved keys or the restored authentication policy.
  /usr/sbin/sshd -t || return 1
  rollback_effective="$transaction_dir/effective-after-rollback"
  capture_effective "$transaction_dir/contexts" "$rollback_effective" || return 1
  [[ -f "$transaction_dir/effective-before.sha256" && ! -L "$transaction_dir/effective-before.sha256" \
    && "$(stat -c '%u:%g:%a:%h' -- "$transaction_dir/effective-before.sha256")" == 0:0:600:1 ]] || return 1
  before_hash="$(<"$transaction_dir/effective-before.sha256")" || return 1
  [[ "$before_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  rollback_hash="$(sha256sum -- "$rollback_effective" | awk '{ print $1 }')" || return 1
  [[ "$before_hash" == "$rollback_hash" ]] || {
    printf 'PHASE1B_ROLLBACK_FAILED: restored effective sshd configuration differs from preimage\n' >&2
    return 1
  }
  systemctl reload ssh.service || return 1
  systemctl is-active --quiet ssh.service || return 1
  verify_live_ssh_runtime_contract || return 1
  restore_transaction_file "$transaction_dir" keys "$AUTHORIZED_KEYS_DIR/$admin_user" || return 1
  restore_transaction_file "$transaction_dir" complete "$COMPLETE" || return 1
  printf 'ROLLED_BACK\n' >"$transaction_dir/rolled-back" || return 1
  chmod 0600 "$transaction_dir/rolled-back" || return 1
  fsync_path "$transaction_dir/rolled-back" || return 1
  fsync_path "$transaction_dir" || return 1
  atomic_remove "$IN_PROGRESS" || return 1
  [[ ! -e "$IN_PROGRESS" && ! -L "$IN_PROGRESS" ]] || return 1
  printf 'PHASE1B_RECOVERED: transaction %s was restored and sshd was reloaded\n' "$txid" >&2
  return 0
}

recover_incomplete_transaction() {
  local txid
  [[ -e "$IN_PROGRESS" || -L "$IN_PROGRESS" ]] || return 0
  [[ -f "$IN_PROGRESS" && ! -L "$IN_PROGRESS" && "$(stat -c '%u:%g:%a:%h' -- "$IN_PROGRESS")" == 0:0:600:1 ]] \
    || die 'unsafe SSH transaction marker; use the physical console and incident procedure'
  txid="$(<"$IN_PROGRESS")"
  [[ "$txid" =~ ^[0-9]{14}-[0-9]+$ ]] \
    || die 'invalid SSH transaction marker; use the physical console and incident procedure'
  rollback_transaction "$txid" \
    || die 'incomplete SSH transaction could not be proven rolled back; keep the console open and stop'
  die 'an incomplete SSH transaction was rolled back; review evidence and rerun the requested operation'
}

recover_incomplete_transaction
verify_phase1_firewall_contract

current_state='none'
if [[ -e "$COMPLETE" || -L "$COMPLETE" ]]; then
  current_state="$(state_value "$COMPLETE" state)" || die 'invalid SSH complete-state file'
  complete_admin="$(state_value "$COMPLETE" admin)" || die 'invalid SSH complete-state admin'
  complete_keyset="$(state_value "$COMPLETE" keyset_sha256)" || die 'invalid SSH complete-state keyset digest'
  complete_office="$(state_value "$COMPLETE" office_cidr)" || die 'invalid SSH complete-state office CIDR'
  complete_vpn="$(state_value "$COMPLETE" vpn_cidr)" || die 'invalid SSH complete-state VPN CIDR'
  complete_port="$(state_value "$COMPLETE" ssh_port)" || die 'invalid SSH complete-state port'
  complete_config_sha="$(state_value "$COMPLETE" config_sha256)" || die 'invalid SSH complete-state config digest'
  [[ "$complete_admin" == "$admin_user" && "$complete_keyset" == "$keyset_sha256" \
    && "$complete_office" == "$office_cidr" && "$complete_vpn" == "$vpn_cidr" \
    && "$complete_port" == "$SSH_PORT" ]] \
    || die 'requested SSH identity/keyset/network differs from the persistent completed state'
  [[ "$current_state" == staged || "$current_state" == key-only ]] || die 'unknown persistent SSH state'
  [[ -f "$CONFIG_PATH" && ! -L "$CONFIG_PATH" && "$(sha256sum -- "$CONFIG_PATH" | awk '{ print $1 }')" == "$complete_config_sha" ]] \
    || die 'managed SSH configuration differs from its persistent completed state'
  [[ -f "$AUTHORIZED_KEYS_PATH" && ! -L "$AUTHORIZED_KEYS_PATH" \
    && "$(sha256sum -- "$AUTHORIZED_KEYS_PATH" | awk '{ print $1 }')" == "$keyset_sha256" ]] \
    || die 'managed root-owned keyset differs from its persistent completed state'
fi

verification_contexts="$(mktemp /run/uten-imp-ssh-contexts.XXXXXX)"
write_contexts "$verification_contexts"
if [[ "$mode" == staged && "$current_state" == key-only ]]; then
  rm -f -- "$verification_contexts"
  die 'refusing to downgrade a completed key-only SSH state back to staging'
fi
if [[ "$mode" == key-only && "$current_state" != staged && "$current_state" != key-only ]]; then
  rm -f -- "$verification_contexts"
  die 'run --stage-keys and test both approved keys before --commit-key-only'
fi
if [[ "$mode" == staged && "$current_state" == staged ]] || [[ "$mode" == key-only && "$current_state" == key-only ]]; then
  validate_desired_effective "$mode" "$verification_contexts"
  verify_ssh_port
  verify_phase1_firewall_contract
  rm -f -- "$verification_contexts"
  printf 'PHASE1B_ALREADY_COMPLETE: state=%s keyset_sha256=%s\n' "$current_state" "$keyset_sha256"
  exit 0
fi

txid="$(date -u +%Y%m%d%H%M%S)-$$"
[[ "$txid" =~ ^[0-9]{14}-[0-9]+$ ]] || die 'failed to create a safe SSH transaction identifier'
transaction_dir="$TRANSACTION_ROOT/$txid"
[[ ! -e "$transaction_dir" && ! -L "$transaction_dir" ]] || die 'SSH transaction directory already exists'
install -d -o 0 -g 0 -m 0700 "$transaction_dir"
validate_root_directory "$transaction_dir"
fsync_path "$transaction_dir"
fsync_path "$TRANSACTION_ROOT"

printf 'state=%s\nadmin=%s\nkeyset_sha256=%s\noffice_cidr=%s\nvpn_cidr=%s\nssh_port=%s\n' \
  "$mode" "$admin_user" "$keyset_sha256" "$office_cidr" "$vpn_cidr" "$SSH_PORT" \
  >"$transaction_dir/metadata"
chmod 0600 "$transaction_dir/metadata"
fsync_path "$transaction_dir/metadata"
cp -- "$verification_contexts" "$transaction_dir/contexts"
chmod 0600 "$transaction_dir/contexts"
fsync_path "$transaction_dir/contexts"
rm -f -- "$verification_contexts"

backup_transaction_file() {
  local label="$1" source_path="$2" source_hash
  if [[ -e "$source_path" || -L "$source_path" ]]; then
    [[ -f "$source_path" && ! -L "$source_path" && "$(stat -c '%u:%g:%h' -- "$source_path")" == 0:0:1 ]] \
      || die "unsafe preimage for $label: $source_path"
    install -o 0 -g 0 -m 0600 -- "$source_path" "$transaction_dir/old-$label"
    stat -c '%a' -- "$source_path" >"$transaction_dir/$label-mode"
    source_hash="$(sha256sum -- "$source_path" | awk '{ print $1 }')"
    printf '%s\n' "$source_hash" >"$transaction_dir/$label-sha256"
    : >"$transaction_dir/had-$label"
    fsync_path "$transaction_dir/old-$label"
    fsync_path "$transaction_dir/$label-mode"
    fsync_path "$transaction_dir/$label-sha256"
    fsync_path "$transaction_dir/had-$label"
  else
    : >"$transaction_dir/absent-$label"
    fsync_path "$transaction_dir/absent-$label"
  fi
}

backup_transaction_file config "$CONFIG_PATH"
backup_transaction_file keys "$AUTHORIZED_KEYS_PATH"
backup_transaction_file complete "$COMPLETE"
capture_effective "$transaction_dir/contexts" "$transaction_dir/effective-before"
sha256sum -- "$transaction_dir/effective-before" | awk '{ print $1 }' >"$transaction_dir/effective-before.sha256"
fsync_path "$transaction_dir/effective-before.sha256"

install -o 0 -g 0 -m 0600 -- "$approved_keys" "$transaction_dir/new-keys"
if [[ "$mode" == staged ]]; then
  cat >"$transaction_dir/new-config" <<EOF
PermitRootLogin no
PubkeyAuthentication yes
AuthorizedKeysFile $AUTHORIZED_KEYS_PATH
AuthorizedKeysCommand none
TrustedUserCAKeys none
StrictModes yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
AllowUsers $admin_user
EOF
else
  cat >"$transaction_dir/new-config" <<EOF
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
AuthenticationMethods publickey
AuthorizedKeysFile $AUTHORIZED_KEYS_PATH
AuthorizedKeysCommand none
TrustedUserCAKeys none
StrictModes yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
AllowUsers $admin_user
EOF
fi
chmod 0600 "$transaction_dir/new-config"
/usr/sbin/sshd -t -f "$transaction_dir/new-config"
new_config_sha="$(sha256sum -- "$transaction_dir/new-config" | awk '{ print $1 }')"
printf 'state=%s\nadmin=%s\nkeyset_sha256=%s\noffice_cidr=%s\nvpn_cidr=%s\nssh_port=%s\nconfig_sha256=%s\n' \
  "$mode" "$admin_user" "$keyset_sha256" "$office_cidr" "$vpn_cidr" "$SSH_PORT" "$new_config_sha" \
  >"$transaction_dir/new-complete"
chmod 0600 "$transaction_dir/new-complete"
fsync_path "$transaction_dir/new-keys"
fsync_path "$transaction_dir/new-config"
fsync_path "$transaction_dir/new-complete"
fsync_path "$transaction_dir"

printf '%s\n' "$txid" >"$transaction_dir/in-progress-candidate"
chmod 0600 "$transaction_dir/in-progress-candidate"
fsync_path "$transaction_dir/in-progress-candidate"
verify_phase1_firewall_contract
atomic_install "$transaction_dir/in-progress-candidate" "$IN_PROGRESS" 0 0 0600
current_txid="$txid"

on_transaction_exit() {
  local exit_code="$1" rollback_code=0 marker_txid=''
  trap - EXIT INT TERM
  set +e
  if [[ -f "$IN_PROGRESS" && ! -L "$IN_PROGRESS" ]]; then
    marker_txid="$(<"$IN_PROGRESS")"
  fi
  if [[ -n "$current_txid" && "$marker_txid" == "$current_txid" ]]; then
    rollback_transaction "$current_txid"
    rollback_code=$?
  fi
  if (( rollback_code != 0 )); then
    printf 'PHASE1B_ROLLBACK_FAILED: keep the physical console open; persistent marker remains at %s\n' "$IN_PROGRESS" >&2
    exit 2
  fi
  exit "$exit_code"
}
trap 'on_transaction_exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

atomic_install "$transaction_dir/new-keys" "$AUTHORIZED_KEYS_PATH" 0 0 0644
atomic_install "$transaction_dir/new-config" "$CONFIG_PATH" 0 0 0644
validate_managed_destination "$AUTHORIZED_KEYS_PATH" 0:0 '644'
validate_managed_destination "$CONFIG_PATH" 0:0 '644'
[[ "$(sha256sum -- "$AUTHORIZED_KEYS_PATH" | awk '{ print $1 }')" == "$keyset_sha256" ]] \
  || die 'installed root-owned keyset digest differs from the approved source'
validate_desired_effective "$mode" "$transaction_dir/contexts"
systemctl reload ssh.service
systemctl is-active --quiet ssh.service
validate_desired_effective "$mode" "$transaction_dir/contexts"
verify_ssh_port
verify_phase1_firewall_contract
atomic_install "$transaction_dir/new-complete" "$COMPLETE" 0 0 0600
printf 'PREPARED_TO_COMMIT\n' >"$transaction_dir/prepared-to-commit"
fsync_path "$transaction_dir/prepared-to-commit"
fsync_path "$transaction_dir"
atomic_remove "$IN_PROGRESS"
current_txid=''
trap - EXIT INT TERM

printf 'PHASE1B_COMPLETE: state=%s keyset_sha256=%s\n' "$mode" "$keyset_sha256"
if [[ "$mode" == staged ]]; then
  printf '%s\n' 'Production remains NO-GO. Test each approved key in a separate new session, verify its out-of-band fingerprint and host key, then run --commit-key-only.'
else
  printf '%s\n' 'Key-only authentication is committed. Keep the console and maintenance session open, prove password/keyboard-interactive refusal, then review and terminate every pre-cutover SSH session.'
fi
