#!/usr/bin/env bash
# Uten IMP 单维护者简化发布链 —— 服务器端更新器（ADR-060）
#
# 用法（root 的 systemd oneshot / 手动）：
#   uten-imp-updater check              # timer 每 5 分钟：拉 LATEST → 验签 → 暂存；
#                                       # 纯代码版本自动激活；含迁移版本仅暂存并提示
#   uten-imp-updater activate <version> # 人工激活含迁移版本：先 pg_dump 全量备份再执行
#   uten-imp-updater status             # 查看当前/最新/已暂存版本
#
# 信任模型：只信 /etc/uten-imp-updater/allowed_signers 钉住的 Ed25519 公钥。
# 验签失败、SHA256 不符、路径含 .. 一律拒装。配置见 /etc/uten-imp-updater.env。
set -euo pipefail

CONFIG=${UTEN_UPDATER_CONFIG:-/etc/uten-imp-updater.env}
# shellcheck source=/dev/null
[ -r "$CONFIG" ] || { echo "缺少配置 $CONFIG（参考 deploy/simple/updater.env.example）" >&2; exit 1; }
. "$CONFIG"

: "${UTEN_OSS_BUCKET:?}" "${UTEN_OSS_ENDPOINT:?}" "${UTEN_OSS_KEY_ID:?}" \
   "${UTEN_OSS_KEY_SECRET:?}" "${UTEN_BASE:=/opt/uten-imp}" \
   "${UTEN_ALLOWED_SIGNERS:=/etc/uten-imp-updater/allowed_signers}" \
   "${UTEN_SIGNER_ID:=uten-imp-release}" "${UTEN_NAMESPACE:=uten-imp-release}" \
   "${UTEN_HEALTH_URL:=http://127.0.0.1:8080/actuator/health/readiness}" \
   "${UTEN_APP_SERVICE:=uten-imp}" "${UTEN_BACKUP_DIR:=/var/backups/uten-imp}" \
   "${UTEN_PG_DATABASE:=uten_imp}" "${UTEN_KEEP_RELEASES:=5}" \
   "${UTEN_AUTO_ACTIVATE_CODE_ONLY:=1}" "${UTEN_MIGRATOR_ENV:=/etc/uten-imp/migrator.env}"

# 会被拼进命令/文件名的值一律限定字符白名单（root 配置文件之外无输入面）
[[ "$UTEN_APP_SERVICE" =~ ^[a-zA-Z0-9@._-]+$ ]] || die "UTEN_APP_SERVICE 含非法字符"
[[ "$UTEN_PG_DATABASE" =~ ^[a-zA-Z0-9_]+$ ]] || die "UTEN_PG_DATABASE 含非法字符"

RELEASES_DIR="$UTEN_BASE/releases"
ACTIVE_FILE="$UTEN_BASE/active-version.txt"
LOCK_FILE=/run/uten-imp-updater.lock
LOG_TAG=uten-imp-updater

log() { echo "[$LOG_TAG] $*"; }
die() { echo "[$LOG_TAG][ERROR] $*" >&2; exit 1; }

urlencode() {
  local s=$1 out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [A-Za-z0-9.~_-]) out+=$c ;;
      *) printf -v c '%%%02X' "'$c"; out+=$c ;;
    esac
  done
  printf '%s' "$out"
}

# OSS V1 签名 GET（只读 RAM 子账号；curl+openssl 零额外依赖）。
# 签名放 Authorization 头：开启版本控制的桶不支持把 V1 签名放 URL 查询参数。
# StringToSign 必须含真实换行：printf 只解释**格式串**里的 \n，参数里的
# \n 是字面反斜杠文本——首装热修版曾因此 403 SignatureDoesNotMatch，务必
# 把换行写在格式串里（2026-09-03 回带仓库时踩过，见 RUNBOOK 已知坑⑥）。
oss_get() {
  local key=$1 date sig
  date=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
  sig=$(printf 'GET\n\n\n%s\n/%s/%s' "$date" "$UTEN_OSS_BUCKET" "$key" \
    | openssl dgst -sha1 -hmac "$UTEN_OSS_KEY_SECRET" -binary | base64 | tr -d '\n')
  curl -fsSL --retry 3 --retry-delay 2 \
    -H "Date: ${date}" \
    -H "Authorization: OSS ${UTEN_OSS_KEY_ID}:${sig}" \
    "https://${UTEN_OSS_BUCKET}.${UTEN_OSS_ENDPOINT}/${key}"
}

# 校验 SHA256SUMS 的每一行：路径必须相对、无 ..，文件哈希必须一致
verify_sums() {
  local dir=$1
  ( cd "$dir" && sha256sum -c SHA256SUMS --quiet ) \
    || die "SHA256SUMS 校验失败：$dir"
}

# 比较两个 JAR 的 Flyway 迁移集（文件名清单哈希）；判定"纯代码"还是"含迁移"。
# server JAR 是 Spring Boot fat jar，资源在 BOOT-INF/classes/db/migration/ 下，
# 必须剥掉前缀再匹配——否则两边都匹配 0 条、哈希恒等，含迁移版本会被误判
# 成纯代码而自动激活（2026-09-03 v2026.09.03-1 事故根因）。
migration_digest() {
  python3 - "$1" <<'PY'
import hashlib, sys, zipfile
def entry_name(e):
    return e[len("BOOT-INF/classes/"):] if e.startswith("BOOT-INF/classes/") else e
names = sorted(
    n for n in (entry_name(e) for e in zipfile.ZipFile(sys.argv[1]).namelist())
    if n.startswith("db/migration/")
)
print(hashlib.sha256("\n".join(names).encode()).hexdigest())
PY
}

current_version() {
  [ -f "$ACTIVE_FILE" ] && cat "$ACTIVE_FILE" || echo none
}

health_ok() {
  curl -fsS --max-time 5 "$UTEN_HEALTH_URL" 2>/dev/null \
    | grep -q '"status"[: ]*"UP"'
}

wait_health() {
  local tries=${1:-40} i
  for ((i = 1; i <= tries; i++)); do
    if health_ok; then return 0; fi
    sleep 3
  done
  return 1
}

# ---------------------------------------------------------------- check ----
do_check() {
  local latest active staged sig_ok tmp key path sum
  latest=$(oss_get "LATEST.txt" | tr -d '[:space:]') || die "无法读取 LATEST.txt"
  [[ "$latest" =~ ^v[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{1,3}$ ]] \
    || die "LATEST.txt 内容非法：$latest"
  active=$(current_version)
  [ "$latest" = "$active" ] && { log "已最新（$active）"; return 0; }

  if [ -d "$RELEASES_DIR/$latest" ]; then
    log "$latest 已暂存（active=$active）"
  else
    log "发现新版本 $latest（active=$active），开始下载暂存"
    tmp=$(mktemp -d "$RELEASES_DIR/.stage-$latest.XXXXXX")
    trap 'rm -rf "$tmp"' RETURN
    ( cd "$tmp"
      oss_get "releases/$latest/SHA256SUMS" > SHA256SUMS
      oss_get "releases/$latest/SHA256SUMS.sig" > SHA256SUMS.sig
      ssh-keygen -Y verify -f "$UTEN_ALLOWED_SIGNERS" -I "$UTEN_SIGNER_ID" \
        -n "$UTEN_NAMESPACE" -s SHA256SUMS.sig < SHA256SUMS 2>/dev/null \
        || die "签名验证失败：$latest"
      while read -r sum path; do
        path=${path#./}
        [[ "$path" =~ ^[A-Za-z0-9._/-]+$ ]] || die "SHA256SUMS 含非法路径：$path"
        [[ "$path" == *".."* ]] && die "SHA256SUMS 含越界/可疑路径：$path"
        [ "$path" = "SHA256SUMS" ] && continue
        mkdir -p "$(dirname "$path")"
        oss_get "releases/$latest/$path" > "$path"
      done < SHA256SUMS
    )
    verify_sums "$tmp"
    mv "$tmp" "$RELEASES_DIR/$latest"
    # 服务账号 uten-imp 需可读；nginx(www-data, 加入 uten-imp 组) 提供 web 静态
    chown -R root:uten-imp "$RELEASES_DIR/$latest"
    chmod -R g+rX "$RELEASES_DIR/$latest"
    log "暂存完成：$RELEASES_DIR/$latest"
  fi

  if [ ! -L "$UTEN_BASE/current" ] || [ ! -d "$UTEN_BASE/current/server" ]; then
    log "首装状态：请人工执行 uten-imp-updater activate $latest"
    return 0
  fi

  local cur_digest new_digest
  cur_digest=$(migration_digest "$UTEN_BASE/current/server/uten-imp-server.jar")
  new_digest=$(migration_digest "$RELEASES_DIR/$latest/server/uten-imp-server.jar")
  if [ "$cur_digest" = "$new_digest" ]; then
    if [ "$UTEN_AUTO_ACTIVATE_CODE_ONLY" = "1" ]; then
      log "$latest 为纯代码更新，自动激活"
      do_activate "$latest" code-only
    else
      log "$latest 已暂存（自动激活已关闭），请人工 activate"
    fi
  else
    log "$latest 含数据库迁移（迁移集有变化），仅暂存。"
    log "维护窗口执行：uten-imp-updater activate $latest（会自动先 pg_dump 备份）"
  fi
}

# ------------------------------------------------------------- activate ----
do_activate() {
  local version=$1 mode=${2:-auto} prev prev_ver code_only backup_file rc
  [[ "$version" =~ ^v[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{1,3}$ ]] \
    || die "版本号非法：$version"
  [ -d "$RELEASES_DIR/$version" ] || die "版本未暂存：$RELEASES_DIR/$version"
  verify_sums "$RELEASES_DIR/$version"

  exec 9>"$LOCK_FILE"
  flock -n 9 || die "另一个更新/激活正在进行（$LOCK_FILE）"

  if [ -L "$UTEN_BASE/current" ]; then
    prev_ver=$(basename "$(readlink -f "$UTEN_BASE/current")")
  else
    prev_ver=none
  fi
  if [ "$mode" = code-only ] || { [ "$prev_ver" != none ] \
      && [ "$(migration_digest "$UTEN_BASE/current/server/uten-imp-server.jar")" \
         = "$(migration_digest "$RELEASES_DIR/$version/server/uten-imp-server.jar")" ]; }; then
    code_only=1
  else
    code_only=0
  fi
  log "激活 $version（previous=$prev_ver, code_only=$code_only）"

  systemctl stop "$UTEN_APP_SERVICE"

  if [ "$code_only" = 0 ]; then
    mkdir -p "$UTEN_BACKUP_DIR"
    backup_file="$UTEN_BACKUP_DIR/${UTEN_PG_DATABASE}-${version}-$(date +%Y%m%d-%H%M%S).dump"
    log "数据库有变化：先全量备份 → $backup_file"
    runuser -u postgres -- pg_dump -Fc -d "$UTEN_PG_DATABASE" > "$backup_file" \
      || die "pg_dump 失败，中止激活（数据库未改动）"
    [ -s "$backup_file" ] || die "备份文件为空，中止激活"
    log "运行 migrator（${UTEN_MIGRATOR_ENV}）"
    set -a; . "$UTEN_MIGRATOR_ENV"; set +a
    timeout 900 /usr/bin/java -jar "$RELEASES_DIR/$version/server/uten-imp-migrator.jar" \
      || { set +a; die "migrator 失败：库已备份在 $backup_file，应用保持停止，请人工排查"; }
    set +a
  fi

  ln -sfn "releases/$version" "$UTEN_BASE/current.new"
  mv -T "$UTEN_BASE/current.new" "$UTEN_BASE/current"
  systemctl start "$UTEN_APP_SERVICE"

  if wait_health; then
    echo "$version" > "$ACTIVE_FILE"
    log "激活成功：$version（健康检查通过）"
    prune_old
    return 0
  fi

  log "健康检查失败：$version"
  ln -sfn "releases/$prev_ver" "$UTEN_BASE/current.new"
  mv -T "$UTEN_BASE/current.new" "$UTEN_BASE/current"
  if [ "$code_only" = 1 ]; then
    systemctl restart "$UTEN_APP_SERVICE" || true
    wait_health 10 || true
    die "已自动回滚到 $prev_ver（应用已恢复）——请检查 $version 的后端日志后重试"
  else
    systemctl stop "$UTEN_APP_SERVICE"
    die "迁移版本失败：已回滚代码到 $prev_ver，应用保持停止。数据库备份：$backup_file。人工恢复后重试"
  fi
}

prune_old() {
  local keep=$UTEN_KEEP_RELEASES active dirs
  active=$(current_version)
  dirs=$(ls -1d "$RELEASES_DIR"/v*/ 2>/dev/null | sed 's:.*/::;s:/$::' | sort -V) || true
  [ -n "$dirs" ] || return 0
  # sort -V 升序，保留最新 $keep 个，其余删除（active 永远在最新之列）
  echo "$dirs" | head -n -"$keep" | while read -r old; do
    rm -rf "$RELEASES_DIR/$old"
    log "清理旧版本：$old"
  done
  return 0
}

# --------------------------------------------------------------- status ----
do_status() {
  echo "active : $(current_version)"
  echo "current -> $(readlink -f "$UTEN_BASE/current" 2>/dev/null || echo 未设置)"
  echo "latest  : $(oss_get "LATEST.txt" 2>/dev/null | tr -d '[:space:]' || echo 无法读取)"
  echo "staged  :"
  ls -1d "$RELEASES_DIR"/v*/ 2>/dev/null | sed 's:.*/::;s:/$::' | sed 's/^/  - /' \
    || echo "  （无）"
  echo "health  : $(health_ok && echo UP || echo DOWN)"
}

case "${1:-check}" in
  check)    do_check ;;
  activate) [ $# -ge 2 ] || die "用法：uten-imp-updater activate <version>"; do_activate "$2" manual ;;
  status)   do_status ;;
  *)        die "未知子命令：$1（可用 check / activate / status）" ;;
esac
