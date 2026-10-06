#!/usr/bin/env bash
# Uten IMP 单维护者简化发布链 —— 服务器端更新器（ADR-060）
#
# 用法（root 的 systemd oneshot / 手动）：
#   uten-imp-updater check              # 手动或本机调度器到期调用（默认每周日当地 05:00）：拉 LATEST → 验签 → 暂存；
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
   "${UTEN_APP_SERVICE:=uten-imp}" "${UTEN_BACKUP_DIR:=/srv/uten-backup/pre-activation}" \
   "${UTEN_PG_DATABASE:=uten_imp}" "${UTEN_KEEP_RELEASES:=5}" "${UTEN_BACKUP_KEEP_DAYS:=3}" \
   "${UTEN_AUTO_ACTIVATE_CODE_ONLY:=1}" "${UTEN_MIGRATOR_ENV:=/etc/uten-imp/migrator.env}"

# 会被拼进命令/文件名的值一律限定字符白名单（root 配置文件之外无输入面）
[[ "$UTEN_APP_SERVICE" =~ ^[a-zA-Z0-9@._-]+$ ]] || die "UTEN_APP_SERVICE 含非法字符"
[[ "$UTEN_PG_DATABASE" =~ ^[a-zA-Z0-9_]+$ ]] || die "UTEN_PG_DATABASE 含非法字符"

RELEASES_DIR="$UTEN_BASE/releases"
ACTIVE_FILE="$UTEN_BASE/active-version.txt"
# /run/lock 是 tmpfs 上的公共锁目录; 更新器 unit 用 ProtectSystem=strict 时只放开它, 不放开整个 /run。
LOCK_FILE=/run/lock/uten-imp-updater.lock
LOG_TAG=uten-imp-updater
# 发行目录属组: 应用账号组可读整个版本; nginx (www-data) 只加入 WEB_GROUP,
# 只能读发行目录里的 web/, server/ 下的 JAR 对它不可见。
APP_GROUP=uten-imp
WEB_GROUP=uten-web
WEB_USER=www-data

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

# OSS V1 签名 = Base64(HMAC-SHA1(Secret, StringToSign)), StringToSign 从标准输入读入。
# 2026-10-06 起 Secret 只经环境变量交给 python, 绝不出现在任何进程的命令行参数里:
# /proc/<pid>/cmdline 本机任何账号都能读, /proc/<pid>/environ 只有同一账号和 root 能读。
# 配置文件只被 source 成 shell 变量 (不 export), 只有这一条命令的环境里带 Secret,
# python 读到后立刻从自己的环境里删掉。
oss_sign() {
  UTEN_OSS_SIGNING_SECRET=$UTEN_OSS_KEY_SECRET python3 -I -c '
import base64, hashlib, hmac, os, sys
secret = os.environ.pop("UTEN_OSS_SIGNING_SECRET").encode()
digest = hmac.new(secret, sys.stdin.buffer.read(), hashlib.sha1).digest()
sys.stdout.write(base64.b64encode(digest).decode())'
}

# OSS V1 签名 GET (只读 RAM 子账号)。
# 签名放 Authorization 头：开启版本控制的桶不支持把 V1 签名放 URL 查询参数。
# StringToSign 必须含真实换行：printf 只解释**格式串**里的 \n，参数里的
# \n 是字面反斜杠文本——首装热修版曾因此 403 SignatureDoesNotMatch，务必
# 把换行写在格式串里（2026-09-03 回带仓库时踩过，见 RUNBOOK 已知坑⑥）。
oss_get() {
  local key=$1 date sig
  date=$(date -u "+%a, %d %b %Y %H:%M:%S GMT")
  sig=$(printf 'GET\n\n\n%s\n/%s/%s' "$date" "$UTEN_OSS_BUCKET" "$key" | oss_sign) \
    || die "OSS 请求签名失败"
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

# web 静态文件给 nginx 的专用组。缺组或 nginx 账号不在组里时宁可不装, 也不回退成把整个
# 发行目录开给 nginx; 否则新版本的 web/ 会让 nginx 读不到, 激活后网页打不开。
require_web_group() {
  getent group "$WEB_GROUP" >/dev/null \
    || die "缺少系统组 $WEB_GROUP：先执行 groupadd --system $WEB_GROUP && usermod -aG $WEB_GROUP $WEB_USER，再 systemctl restart nginx (见 RUNBOOK「发行目录权限」)"
  if id -u "$WEB_USER" >/dev/null 2>&1 \
      && ! id -nG "$WEB_USER" | tr ' ' '\n' | grep -qx -- "$WEB_GROUP"; then
    die "$WEB_USER 不在 $WEB_GROUP 组：先执行 usermod -aG $WEB_GROUP $WEB_USER，再 systemctl restart nginx (见 RUNBOOK「发行目录权限」)"
  fi
}

# 发行目录权限 (2026-10-06 起):
#   releases/<v>        root:uten-imp 0751  其他账号只能穿过, 不能列目录
#   releases/<v>/server root:uten-imp 0750  应用账号可读 JAR, nginx 读不到
#   releases/<v>/web    root:uten-web 0750  只有 nginx 可读 (目录 0750 / 文件 0640)
# 暂存和激活都调用一次, 旧更新器暂存的版本激活前也会被收紧。幂等。
publish_release_permissions() {
  local dir=$1
  chown -R "root:$APP_GROUP" -- "$dir"
  chmod -R g+rX,o-rwx -- "$dir"
  if [ -d "$dir/web" ]; then
    chgrp -R "$WEB_GROUP" -- "$dir/web"
  fi
  chmod 0751 -- "$dir"
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
  [[ "$latest" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "LATEST.txt 内容非法：$latest"
  active=$(current_version)
  [ "$latest" = "$active" ] && { log "已最新（$active）"; return 0; }

  if [ -d "$RELEASES_DIR/$latest" ]; then
    log "$latest 已暂存（active=$active）"
  else
    require_web_group
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
    publish_release_permissions "$RELEASES_DIR/$latest"
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

# Dumps contain the full business database, including account hashes. Create
# their directory/file with explicit private modes, independent of systemd's
# umask. A unique pre-created file also prevents a same-second retry overwriting
# the previous backup. Release artifacts keep their existing readable modes.
# pg_dump writes to a ".partial" name first; only a finished, non-empty dump is
# hard-linked to the final name (ln never overwrites), so a failed, empty or
# killed dump can never be mistaken for the newest backup by the cleanup below.
create_database_backup() {
  local version=$1 partial backup_file
  install -d -m 0700 -- "$UTEN_BACKUP_DIR" || return 1
  partial=$(mktemp -- "$UTEN_BACKUP_DIR/${UTEN_PG_DATABASE}-${version}-$(date +%Y%m%d-%H%M%S).XXXXXX.dump.partial") \
    || return 1
  backup_file=${partial%.partial}
  log "数据库有变化：先全量备份 → $backup_file" >&2
  if runuser -u postgres -- pg_dump -Fc -d "$UTEN_PG_DATABASE" > "$partial" && [ -s "$partial" ] \
      && ln -T -- "$partial" "$backup_file"; then
    rm -f -- "$partial"
    printf '%s\n' "$backup_file"
    return 0
  fi
  rm -f -- "$partial"
  return 1
}

# 升级前 dump 只是短期回退点 (长期历史由每日配套备份与 pgBackRest 保留)。
# 只认本更新器自己生成的文件名 (create_database_backup 的格式, 含中断留下的
# .partial)、UTEN_BACKUP_DIR 下一层的普通文件、非符号链接; 年龄取文件名里的时间
# (不看 mtime), 保留最近 UTEN_BACKUP_KEEP_DAYS 个日历日 (含当天)。「最新一份永远
# 保留」只在已完成的非空 dump 里选, .partial 和空文件不算, 只按日期清理。
# 人工 dump、子目录和其它名字一律不碰; 任何异常只记日志, 不影响激活结果。
prune_database_backups() {
  local keep_days=$UTEN_BACKUP_KEEP_DAYS dir=$UTEN_BACKUP_DIR oldest newest="" path name stamp day size
  local pattern="^${UTEN_PG_DATABASE}-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-([0-9]{8})-([0-9]{6})\.[A-Za-z0-9]{6}\.dump(\.partial)?$"
  if ! [[ "$keep_days" =~ ^[1-9][0-9]{0,2}$ ]] || [ "$keep_days" -gt 365 ]; then
    log "跳过升级前备份清理: UTEN_BACKUP_KEEP_DAYS 必须为 1 至 365 的整数"
    return 0
  fi
  if [ -L "$dir" ] || [ ! -d "$dir" ]; then
    return 0
  fi
  if ! oldest=$(date -d "-$((keep_days - 1)) days" +%Y%m%d); then
    log "跳过升级前备份清理: 无法计算保留起始日期"
    return 0
  fi
  for path in "$dir"/*.dump; do
    name=${path##*/}
    if [[ "$name" =~ $pattern ]] && [ -f "$path" ] && [ ! -L "$path" ] && [ -s "$path" ]; then
      stamp="${BASH_REMATCH[4]}${BASH_REMATCH[5]}"
      if [ -z "$newest" ] || [[ "$stamp" > "$newest" ]]; then
        newest=$stamp
      fi
    fi
  done
  # 没有任何完成的 dump 时一个都不删 (连 .partial 也留给人工核对)。
  [ -n "$newest" ] || return 0
  for path in "$dir"/*.dump "$dir"/*.dump.partial; do
    name=${path##*/}
    if ! [[ "$name" =~ $pattern ]] || [ ! -f "$path" ] || [ -L "$path" ]; then
      continue
    fi
    day=${BASH_REMATCH[4]}
    stamp="$day${BASH_REMATCH[5]}"
    if ! [[ "$day" < "$oldest" ]] \
        || { [ "$stamp" = "$newest" ] && [ -z "${BASH_REMATCH[6]}" ] && [ -s "$path" ]; }; then
      continue
    fi
    size=$(stat -c %s -- "$path" 2>/dev/null) || size="?"
    if rm -f -- "$path"; then
      log "清理过期升级前备份: $name (释放 $size 字节, 保留最近 ${keep_days} 天)"
    else
      log "升级前备份清理失败: $name"
    fi
  done
  return 0
}

# ------------------------------------------------------------- activate ----
do_activate() {
  local version=$1 mode=${2:-auto} prev prev_ver code_only backup_file rc
  [[ "$version" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
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

  # 停应用之前完成所有可能失败的准备, 失败时应用照常运行: web 组与发行目录权限
  # (旧更新器暂存的版本在这里被收紧), 以及含迁移版本的备份目录。
  require_web_group
  publish_release_permissions "$RELEASES_DIR/$version"
  if [ "$code_only" = 0 ]; then
    install -d -m 0700 -- "$UTEN_BACKUP_DIR" \
      || die "升级前备份目录不可写：$UTEN_BACKUP_DIR (备份盘没挂载?), 未停应用、未改数据库"
  fi

  systemctl stop "$UTEN_APP_SERVICE"

  if [ "$code_only" = 0 ]; then
    backup_file=$(create_database_backup "$version") \
      || die "数据库备份失败或为空，中止激活（数据库未改动）"
    log "运行 migrator（${UTEN_MIGRATOR_ENV}）"
    set -a; . "$UTEN_MIGRATOR_ENV"; set +a
    timeout 900 /usr/bin/java -jar "$RELEASES_DIR/$version/server/uten-imp-migrator.jar" \
      || { set +a; die "migrator 失败：库已备份在 $backup_file，应用保持停止，请人工排查"; }
    set +a
  fi

  ln -sfn "releases/$version" "$UTEN_BASE/current.new"
  mv -T "$UTEN_BASE/current.new" "$UTEN_BASE/current"
  # A failed systemctl start must use the same recovery path as an unhealthy
  # process; an unguarded command would exit here under set -e.
  if systemctl start "$UTEN_APP_SERVICE" && wait_health; then
    echo "$version" > "$ACTIVE_FILE"
    log "激活成功：$version（健康检查通过）"
    prune_old
    prune_database_backups
    return 0
  fi

  log "启动或健康检查失败：$version"
  if [ "$prev_ver" != none ]; then
    ln -sfn "releases/$prev_ver" "$UTEN_BASE/current.new"
    mv -T "$UTEN_BASE/current.new" "$UTEN_BASE/current"
  else
    # First activation has no old release to restore, never create releases/none.
    rm -f -- "$UTEN_BASE/current"
  fi
  if [ "$code_only" = 1 ] && [ "$prev_ver" != none ]; then
    if systemctl restart "$UTEN_APP_SERVICE" && wait_health 10; then
      die "已自动回滚到 $prev_ver（应用已恢复）——请检查 $version 的后端日志后重试"
    fi
    systemctl stop "$UTEN_APP_SERVICE" \
      || die "已回滚代码到 $prev_ver，但应用恢复失败且停止失败，请立即人工排查"
    die "已回滚代码到 $prev_ver，但应用未恢复，已停止；请人工排查"
  else
    systemctl stop "$UTEN_APP_SERVICE" \
      || die "迁移版本激活失败且应用停止失败，请立即人工排查；数据库备份：$backup_file"
    die "迁移版本失败：代码已恢复到先前状态（previous=$prev_ver），应用保持停止。数据库备份：$backup_file。人工恢复后重试"
  fi
}

release_versions() {
  local directory version
  # A glob ending in '/' cannot be trimmed with s:.*/::: that also removes
  # the version itself. Only verified-format directory names enter retention.
  for directory in "$RELEASES_DIR"/v*/; do
    [ -d "$directory" ] || continue
    version=${directory%/}
    version=${version##*/}
    [[ "$version" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || continue
    printf '%s\n' "$version"
  done | sort -V
}

# 保留策略只认 vX.Y.Z 目录; 其它名字 (旧日期号版本、手工拷贝等) 永远不会被自动清理,
# 每次清理时在日志里点名, 提醒人工核对后删除, 不让它们悄悄堆满磁盘。
# 下载中的 .stage-* 由 do_check 自己收尾, 不算。
report_unrecognized_releases() {
  local entry name
  for entry in "$RELEASES_DIR"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=${entry##*/}
    if [ -d "$entry" ] && [ ! -L "$entry" ] \
        && [[ "$name" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
      continue
    fi
    log "发行目录里有不认识的条目：$name (不会自动清理, 请人工核对后删除)"
  done
  return 0
}

current_link_version() {
  [ -L "$UTEN_BASE/current" ] || return 1
  basename "$(readlink -f "$UTEN_BASE/current")"
}

prune_old() {
  local keep=$UTEN_KEEP_RELEASES active actual dirs
  [[ "$keep" =~ ^[1-9][0-9]{0,3}$ ]] || {
    log "跳过清理：UTEN_KEEP_RELEASES 必须为 1 至 9999 的整数"
    return 0
  }
  active=$(current_version)
  actual=$(current_link_version) || {
    log "跳过清理：无法核对 current 运行目录"
    return 0
  }
  [[ "$active" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ && "$actual" = "$active" ]] || {
    log "跳过清理：版本记录与 current 运行目录不一致"
    return 0
  }
  report_unrecognized_releases
  dirs=$(release_versions)
  [ -n "$dirs" ] || return 0
  # sort -V 升序，保留最新 $keep 个，其余删除。
  # 「active 永远在最新之列」只在版本号方案单一时成立——一旦混用两种方案
  #（如日期号 v2026.09.09-1 与语义化号 v1.0.0），sort -V 会把语义化号排在前面，
  # 正在跑的那一版就可能被当成旧版删掉，服务器当场失去 current 指向的目录。
  # 所以这里加一条硬保护：**永不删除 active**。与版本号方案无关，属独立健壮性底线。
  echo "$dirs" | head -n -"$keep" | while read -r old; do
    if [ "$old" = "$active" ]; then
      log "跳过清理：$old 正在使用中"
      continue
    fi
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
  local staged
  staged=$(release_versions)
  if [ -n "$staged" ]; then
    printf '%s\n' "$staged" | sed 's/^/  - /'
  else
    echo "  （无）"
  fi
  echo "health  : $(health_ok && echo UP || echo DOWN)"
}

case "${1:-check}" in
  check)    do_check ;;
  activate) [ $# -ge 2 ] || die "用法：uten-imp-updater activate <version>"; do_activate "$2" manual ;;
  status)   do_status ;;
  *)        die "未知子命令：$1（可用 check / activate / status）" ;;
esac
