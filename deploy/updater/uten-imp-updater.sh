#!/usr/bin/env bash
# Uten IMP 拉取式自动更新器（服务器侧）。
# 每 5 分钟由 uten-imp-updater.timer 触发：
#   读 OSS releases/LATEST.txt -> 与 current 版本比较 -> 下载 tar+sha256 校验 ->
#   解压到 releases/<version> -> 校验 SHA256SUMS -> 停 watchdog -> 停后端 ->
#   原子切换 current -> 启动 -> 健康检查（失败自动回滚）-> 恢复 watchdog。
# 凭证从 /etc/uten-imp/oss-pull.env（0640 root:uten-imp）读取，只读 RAM 账号。
set -euo pipefail

BASE=/opt/uten-imp
RELEASES="$BASE/releases"
CURRENT="$BASE/current"
UPDATER="$BASE/updater"
ENV_FILE=/etc/uten-imp/oss-pull.env
LOCK=/run/uten-imp-updater.lock
LOG_TAG=uten-imp-updater

log() { logger -t "$LOG_TAG" -- "$*"; echo "$*"; }
die() { log "ERROR: $*"; exit 1; }

exec 9>"$LOCK"
flock -n 9 || { log "another updater is running, skip"; exit 0; }

[ -r "$ENV_FILE" ] || die "missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

PY="$UPDATER/venv/bin/python"
[ -x "$PY" ] || die "updater venv missing"

latest_tmp="$(mktemp /run/uten-imp-latest.XXXXXX)"
trap 'rm -f "$latest_tmp"' EXIT
"$PY" "$UPDATER/oss_io.py" get releases/LATEST.txt "$latest_tmp" 2>/dev/null \
  || die "cannot read releases/LATEST.txt from OSS"
remote_version="$(tr -d '[:space:]' < "$latest_tmp")"
[[ "$remote_version" =~ ^[A-Za-z0-9._-]+$ ]] || die "bad version string: $remote_version"

local_version=""
if [ -L "$CURRENT" ]; then
  local_version="$(basename "$(readlink -f "$CURRENT")")"
fi
if [ "$remote_version" = "$local_version" ]; then
  exit 0
fi
log "new version detected: $local_version -> $remote_version"

stage="$(mktemp -d /run/uten-imp-update.XXXXXX)"
trap 'rm -rf "$stage"; rm -f "$latest_tmp"' EXIT

tarball="uten-imp-${remote_version}.tar.gz"
"$PY" "$UPDATER/oss_io.py" get "releases/${remote_version}/${tarball}" "$stage/$tarball" \
  || die "download tarball failed"
"$PY" "$UPDATER/oss_io.py" get "releases/${remote_version}/${tarball}.sha256" "$stage/${tarball}.sha256" \
  || die "download checksum failed"
(cd "$stage" && sha256sum -c "${tarball}.sha256") || die "tarball checksum mismatch"

target="$RELEASES/$remote_version"
[ -d "$target" ] && die "release dir already exists: $target"
staging_dir="$RELEASES/.staging-$remote_version"
rm -rf "$staging_dir"
mkdir -p "$staging_dir"
tar -xzf "$stage/$tarball" -C "$staging_dir"
mv "$staging_dir/$remote_version" "$target"
rmdir "$staging_dir"

(cd "$target" && sha256sum -c SHA256SUMS >/dev/null) || die "SHA256SUMS verify failed"
test "$(stat -c %d "$BASE")" = "$(stat -c %d "$target")" || die "release dir on different filesystem"

# 切换（单机维护窗口：短暂停服数秒，失败自动回滚）
systemctl stop uten-imp-watchdog.timer uten-imp-entry-watchdog.timer 2>/dev/null || true
systemctl stop uten-imp-watchdog.service uten-imp-entry-watchdog.service 2>/dev/null || true
had_current=0
if [ -L "$CURRENT" ]; then had_current=1; fi
old_target=""
[ "$had_current" = 1 ] && old_target="$(readlink -f "$CURRENT")"

systemctl stop uten-imp.service 2>/dev/null || true
ln -s "releases/$remote_version" "$BASE/.current-$remote_version"
mv -Tf "$BASE/.current-$remote_version" "$CURRENT"

rollback() {
  log "health check failed, rolling back to ${old_target:-none}"
  if [ -n "$old_target" ]; then
    ln -sfn "$old_target" "$BASE/.current-rollback"
    mv -Tf "$BASE/.current-rollback" "$CURRENT"
    systemctl start uten-imp.service || true
  else
    rm -f "$CURRENT"
  fi
  systemctl start uten-imp-watchdog.timer uten-imp-entry-watchdog.timer 2>/dev/null || true
  exit 1
}

systemctl start uten-imp.service
ok=0
for _ in $(seq 1 100); do
  sleep 3
  if curl --fail --silent --max-time 5 http://127.0.0.1:8080/actuator/health \
      | grep -q '"status":"UP"'; then ok=1; break; fi
done
[ "$ok" = 1 ] || rollback

systemctl reload nginx 2>/dev/null || true
systemctl start uten-imp-watchdog.timer uten-imp-entry-watchdog.timer 2>/dev/null || true
log "updated to $remote_version successfully"
