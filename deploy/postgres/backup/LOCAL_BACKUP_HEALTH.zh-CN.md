# 本地双仓只读健康检查

现役本地布局为 repo1 `/data/backups/pgbackrest`、repo2 `/srv/uten-backup/pgbackrest`。健康入口是本目录
`local_backup_health.py`，共用 `pgbackrest_health.py` 的数据库身份、恢复点和 WAL 解析，恢复点下限共用
`pgbackrest_repo2.py` 的 `MINIMUM_RESTORE_POINTS=3`。不使用旧异地 repo2 的 S3 policy/commissioner 流程。

每次先只读 PostgreSQL 主库的归档状态，再读两个本地仓的 `pgbackrest info --output=json`，最后读 Flyway 历史。
两仓各要求至少 3 个不同 UTC 日期的成功全量点，最近全量不早于 30 小时；PostgreSQL 最近归档成功不早于 15 分钟，
且最近一次归档失败不能晚于成功。各仓必须包含同一数据库 system identifier，并覆盖本次查询前已经成功的 WAL。
两次 info 之间允许 WAL 正常前进，不以两个采样最大 WAL 必须相同来制造误报。

程序不执行 backup、check、expire、restore、archive-push，也不修改数据库、备份仓和配置。psql 固定连接本机 Unix
socket，显式 `BEGIN READ ONLY`、15 秒语句上限与 1 秒锁上限；pgBackRest 文件日志关闭。只写自己的健康报告。
恢复点数量和 WAL 最后位置不等于完整连续性、异地不可变证明或实际恢复演练，这些标志在报告中明确为 false。

## 与平台状态页的连接

输出仍为 `/var/lib/uten-imp-backup-health/health.json` 的 `schemaVersion=1`，成功为 `PASS`，采样/解析失败为
`FAIL`。`server_status_export.py` 继续只导出最小 `uten-server-backup-status-v1` 摘要，后台 `BackupHealth`、
服务器状态页与平台内告警沿现有通道消费。原始异常、配置、凭证和数据库详情不进入平台摘要；健康检查失败表示
「检查未通过」，不伪装成新备份失败，也不刷新旧备份成功时间。

现役单元为 `deploy/simple/units/uten-pgbackup-health.{service,timer}`。以 postgres 身份运行，每 5 分钟一次，
只开放健康状态目录写入，禁止网络，只允许 Unix socket；失败走平台内 `uten-alert@`。旧
`deploy/systemd/uten-pgbackup-health.*.example` 属于保留的受控双仓恢复链样例，不能覆盖本地现役单元。

## 安装与回滚交接

以下是候选版本交接步骤，仓库验证不表示服务器已安装。安装前只读核对并保存实际健康 service/timer、旧
`/usr/local/libexec/uten-imp-monitoring/local_backup_health.py`、现有健康 JSON 的权限与摘要，以及当前两个仓的
配置编号/恢复点。确认实际布局与上文一致；旧链若仍执行恢复/发布门禁，应先核清用途，不能混装。

维护窗口内从已验收提交的原始 Git blob 安装，脚本 root:root 0755：

```bash
sudo install -d -o root -g root -m 0755 /usr/local/libexec/uten-imp-backup
sudo install -o root -g root -m 0755 deploy/postgres/backup/local_backup_health.py /usr/local/libexec/uten-imp-backup/local_backup_health.py
sudo install -o root -g root -m 0755 deploy/postgres/backup/pgbackrest_health.py /usr/local/libexec/uten-imp-backup/pgbackrest_health.py
sudo install -o root -g root -m 0755 deploy/postgres/backup/pgbackrest_repo2.py /usr/local/libexec/uten-imp-backup/pgbackrest_repo2.py
sudo install -o root -g root -m 0644 deploy/simple/units/uten-pgbackup-health.service /etc/systemd/system/uten-pgbackup-health.service
sudo install -o root -g root -m 0644 deploy/simple/units/uten-pgbackup-health.timer /etc/systemd/system/uten-pgbackup-health.timer
sudo systemctl daemon-reload
sudo systemctl start uten-pgbackup-health.service
```

先核验 helper/unit 的 SHA 与验收提交一致；这次 service 必须成功，健康 JSON 下限为 3、两仓身份及恢复点正确，
再由状态导出单元确认平台摘要没有泄漏原始细节。随后启用 timer。保留 3 份的设置只能在健康入口已切换并验收后
生效；仓库变更不直接更改服务器保留配置。旧的未版本化脚本移出执行路径，仅留在本次回滚包内，避免出现两个维护源。

回滚时停 timer，恢复先前保存的两个单元与旧脚本及必要目录权限，`daemon-reload` 后重新运行旧健康服务确认，再恢复
原 timer 状态。不回退数据库、不删健康失败证据、不触发新备份或过期清理。配套备份原件去重是独立脚本变更，按其
手册安装和验收，不能以此健康检查通过替代配套备份恢复演练。
