#!/bin/bash
# 服务器告警发送 (ADR-157)。安装为 /usr/local/sbin/uten-alert (root:root 0755)。
# 用法: uten-alert <事件名> [补充说明]
#   由 uten-alert@.service (各单元 OnFailure=) 和 uten-host-check 调用, 也可手工 `uten-alert test`。
# 只发固定的大白话: 不带日志原文、路径、库名或任何密钥; 同一事件 6 小时内只发一次。
# webhook 地址只放在 /etc/uten-imp/alert.curl (root 0600, 一行 url = "..."), 用 curl -K 读取,
# 不出现在任何进程的命令行参数里。告警通道由用户决定 (治理记录 D1), 未接入前不安装本脚本。
set -euo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

ev=${1:-unknown}
ev=${ev%.service}
detail=${2:-}
case "$ev" in
  test*)                       text="告警通道测试, 无需处理" ;;
  uten-pgbackup)               text="每日数据库备份失败" ;;
  uten-paired-internal-backup) text="数据库加附件的配套备份失败" ;;
  uten-imp)                    text="ERP 后台反复崩溃, 已停止自动重启" ;;
  uten-imp-updater)            text="自动更新检查出错" ;;
  disk-*)                      text="磁盘空间不足" ;;
  diskwarn-*)                  text="磁盘已用超过八成" ;;
  raid-*)                      text="数据盘阵列异常, 可能有硬盘坏了" ;;
  smart-*)                     text="硬盘健康预警" ;;
  down-*)                      text="有服务没在运行" ;;
  wal-archive)                 text="数据库日志归档失败, 按时间点恢复会断档" ;;
  backup-stale*)               text="备份太久没有成功了" ;;
  *)                           text="服务器出现需要人工查看的问题" ;;
esac

state=/var/lib/uten-alert
install -d -m 0700 "$state"
mark="$state/$(printf '%s' "$ev" | sha256sum | cut -c1-16)"
if [ -f "$mark" ] && [ $(( $(date +%s) - $(stat -c %Y "$mark") )) -lt 21600 ]; then
  exit 0
fi

message="[ERP 服务器 $(hostname)] $text${detail:+ ($detail)}. 时间 $(date '+%F %T'), 请尽快处理."
# 企业微信与钉钉群机器人都接受这个 text 消息格式; 钉钉若开了"自定义关键词", 关键词用"ERP"。
python3 -I -c 'import json, sys; print(json.dumps({"msgtype": "text", "text": {"content": sys.argv[1]}}, ensure_ascii=False))' "$message" \
  | curl -fsS --max-time 15 --retry 2 -K /etc/uten-imp/alert.curl \
      -H 'Content-Type: application/json' --data-binary @- >/dev/null
touch "$mark"
