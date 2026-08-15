#!/usr/bin/env bash
# Unprivileged, read-only OSS staging. This never activates a release.
set -Eeuo pipefail
export PATH=/usr/local/bin:/usr/bin:/bin
umask 077
readonly ENV_FILE=/etc/uten-website/oss-read.env
readonly STAGED=/var/lib/uten-website/updater/staged
readonly TRUST=/etc/uten-website/release-allowed-signers
readonly TOOL=/usr/local/libexec/uten-website/website_release.py
readonly LOCK=/run/uten-website-stage/stage.lock
die() { printf 'WEBSITE_STAGE_REFUSED: %s\n' "$*" >&2; exit 1; }
[[ ${EUID} -ne 0 ]] || die 'stager must not run as root'
[[ $# -eq 0 ]] || die 'fixed channel stager accepts no arguments'
[[ -f $ENV_FILE && ! -L $ENV_FILE && -f $TRUST && ! -L $TRUST && -x $TOOL ]] || die 'stager configuration/trust/tool is missing'
[[ $(stat -c '%U:%G:%a:%h' "$ENV_FILE") == root:uten-website-updater:640:1 ]] \
  || die 'oss-read.env must be root:uten-website-updater 0640 with one link'
eval "$(python3 -I - "$ENV_FILE" <<'PY'
import re,shlex,sys
raw=open(sys.argv[1],'rb').read()
if not raw or len(raw)>8192 or b'\0' in raw or b'\r' in raw: raise SystemExit('unsafe oss-read.env')
allowed={'WEBSITE_OSS_BUCKET','WEBSITE_OSS_ENDPOINT'}; values={}
for number,line in enumerate(raw.decode().splitlines(),1):
 if not line or line.startswith('#'): continue
 m=re.fullmatch(r'([A-Z][A-Z0-9_]*)=([^\s\'"`$#;\\]+)',line)
 if not m or m.group(1) not in allowed or m.group(1) in values: raise SystemExit(f'unsafe oss-read.env line {number}')
 values[m.group(1)]=m.group(2)
if set(values)!=allowed: raise SystemExit('oss-read.env key set differs')
if not re.fullmatch(r'[a-z0-9][a-z0-9-]{2,62}',values['WEBSITE_OSS_BUCKET']): raise SystemExit('invalid bucket')
if not re.fullmatch(r'https://[a-z0-9.-]+(?::443)?',values['WEBSITE_OSS_ENDPOINT']): raise SystemExit('invalid HTTPS endpoint')
for k,v in values.items(): print(f'{k}={shlex.quote(v)}')
PY
)" || die 'cannot parse OSS read-only environment'
export WEBSITE_OSS_BUCKET WEBSITE_OSS_ENDPOINT
exec 9>"$LOCK"; flock -n 9 || die 'staging lock is held'
work="$(mktemp -d --tmpdir="$STAGED" .candidate.XXXXXX)"
trap 'rm -rf -- "$work"' EXIT
fetch() {
  local key=$1 destination=$2
  [[ $key == website/* && $key != *..* && $key != *//* ]] || die "unsafe OSS object key: $key"
  ossutil cp --force --endpoint "$WEBSITE_OSS_ENDPOINT" "oss://$WEBSITE_OSS_BUCKET/$key" "$destination"
  [[ -f $destination && ! -L $destination ]] || die "OSS download is not a regular file: $key"
}
fetch website/channels/candidate.json "$work/channel.json"
fetch website/channels/candidate.sig "$work/channel.sig"
ssh-keygen -Y verify -f "$TRUST" -I uten-website-release -n uten-website-release-v2 -s "$work/channel.sig" <"$work/channel.json" \
  || die 'candidate channel signature is invalid'
mapfile -t channel < <(python3 -I - "$work/channel.json" <<'PY'
import json,re,sys
raw=open(sys.argv[1],'rb').read(); v=json.loads(raw)
canonical=(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n').encode()
if raw!=canonical or set(v)!={'artifactObjectKey','manifestObjectKey','manifestSha256','product','schemaVersion','version'}: raise SystemExit('channel contract differs')
version=v['version']; prefix=f'website/releases/{version}/'
if v['product']!='uten-corporate-website' or v['schemaVersion']!=2 or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?',version): raise SystemExit('channel identity differs')
if not v['artifactObjectKey'].startswith(prefix) or v['manifestObjectKey']!=prefix+'manifest.json': raise SystemExit('channel object namespace differs')
print(version); print(v['artifactObjectKey']); print(v['manifestObjectKey']); print(v['manifestSha256'])
PY
)
[[ ${#channel[@]} -eq 4 ]] || die 'candidate channel cannot be parsed'
version=${channel[0]}; artifact_key=${channel[1]}; manifest_key=${channel[2]}; manifest_sha=${channel[3]}
artifact_name=${artifact_key##*/}; prefix=${manifest_key%manifest.json}
fetch "$manifest_key" "$work/manifest.json"
[[ $(sha256sum "$work/manifest.json" | awk '{print $1}') == "$manifest_sha" ]] || die 'manifest differs from signed channel digest'
fetch "${prefix}manifest.sig" "$work/manifest.sig"
fetch "${prefix}website-sbom.cdx.json" "$work/website-sbom.cdx.json"
fetch "$artifact_key" "$work/$artifact_name"
fetch "$artifact_key.sha256" "$work/$artifact_name.sha256"
python3 -I "$TOOL" verify --publication "$work" --allowed-signers "$TRUST" --expected-version "$version"
target=$STAGED/$version
if [[ -e $target || -L $target ]]; then
  [[ -d $target && ! -L $target ]] || die 'existing staged version is unsafe'
  python3 -I "$TOOL" verify --publication "$target" --allowed-signers "$TRUST" --expected-version "$version"
  printf 'WEBSITE_STAGE_ALREADY_VERIFIED version=%s\n' "$version"
  exit 0
fi
mv -- "$work" "$target"
trap - EXIT
printf 'WEBSITE_STAGE_OK version=%s path=%s\n' "$version" "$target"
