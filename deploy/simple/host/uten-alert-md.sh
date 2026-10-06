#!/bin/sh
# mdadm --monitor 的 PROGRAM 钩子。安装为 /usr/local/sbin/uten-alert-md (root 0755),
# 并在 /etc/mdadm/mdadm.conf 末尾加一行: PROGRAM /usr/local/sbin/uten-alert-md
case "$1" in
  TestMessage) exec /usr/local/sbin/uten-alert test-md "磁盘阵列告警测试" ;;
  Fail|FailSpare|DegradedArray|DeviceDisappeared|SparesMissing)
    exec /usr/local/sbin/uten-alert "raid-$1" "$2 $3" ;;
esac
exit 0
