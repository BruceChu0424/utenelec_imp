#!/bin/sh
# smartd 发现硬盘预警时调用 (smartd.conf 的 -M exec)。安装为 /usr/local/sbin/uten-alert-smart (root 0755)。
exec /usr/local/sbin/uten-alert "smart-${SMARTD_DEVICE:-unknown}" "${SMARTD_DEVICE:-} ${SMARTD_FAILTYPE:-}"
