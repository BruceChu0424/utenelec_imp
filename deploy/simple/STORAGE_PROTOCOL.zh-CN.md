# 本机存储接口与保护协议

应用使用 `server_status:view`、`server:update`、`server:cleanup` 任一权限读取。只有独立授予
`server:cleanup` 的员工或超级管理员可以预览与删除；两步都沿用再次认证，模拟身份及强制改密账号禁止写。
服务端自行绑定账号、requestId 和固定 socket，不接收客户端主机、目录、命令或配置路径。

## API

- `GET /api/admin/server-storage`：真实卷容量（按设备去重）、目录逻辑/分配大小、RSS 与 Java 堆、
  `pg_database_size`、全部附件登记量。登记量含历史原件，不是物理对象去重总量；不同目录可能重叠。
- `GET /api/admin/server-storage/resources?kind=...&cursor=...&limit=50`：固定用途直属条目与受保护原因。
  `limit` 上限 100；响应按字节有界，因此始终用 `nextCursor` 判断是否还有下一页。
- `POST /api/admin/server-storage/cleanup/preview`：`{resourceIds:[opaqueId]}`，最多 50 项，返回
  `previewId/expiresAt/revision/resources/totalReclaimableBytes/confirmationText/warnings`。
- `POST /api/admin/server-storage/cleanup`：`{previewId:UUID,requestId:UUID}`，返回
  `requestId/status/deletedCount/reclaimedBytes/detail`。状态为 `RUNNING/SUCCEEDED/PARTIAL/FAILED/RECOVERY_REQUIRED`。
- `GET /api/admin/server-storage/cleanup/{requestId}`：只读、账号绑定的持久回执。超时后只查询同一个
  requestId，不能重新 POST。404 只表示暂未查到回执，不能证明请求未执行。
  共同锁空闲但仍留 RUNNING 的中断意图标为 `RECOVERY_REQUIRED`，不会重放删除。

`kind` 为 `SYSTEM/RELEASES/RELEASE_STAGING/PREACTIVATION_BACKUPS/PAIRED_BACKUPS/DATABASE/UPLOADS/LEGACY_UPLOADS/LOGS/CACHE`。
`UPLOADS` 仅统计当前上传目录；可选 `LEGACY_UPLOADS` 独立统计兼容旧 local 原件目录。
后者只由可信安装配置从正式配套备份 `local_media_root` 派生并核对运行时绑定，客户端不能提供路径；
未配置时省略，有配置但不可读取时明确返回未知，两类原件都永不提供文件级清理。
未知数值返回 null；超出扫描预算不会返回部分数值冒充完整占用。卷容量与目录占用不可相加。
目录扫描每分钟缓存，预览与删除重新扫描并校验保护状态。`allocatedBytes` 使用分配块计数；
硬链接按 inode 去重，释放估算只计本次删除最后一个链接的分配块与目录块，不能当作整卷前后净变化。
Linux RSS 读取 `/proc/self/status`；Windows 开发环境没有主机助手，RSS 明确不可用，Java 堆仍单独显示。

## 可清理范围

数据库、上传原件（包括逻辑删除后的保留历史及私有文档）、缺少完整租约事实的派生缓存始终只读。
杀毒拒绝的 staging 由既有附件核对/outbox 管理，不能通过本接口绕过业务引用与版本锁。

下载失败暂存需整棵树至少 24 小时未修改；日志只支持超过七天的 `*.log.<数字>.gz` 闭合普通文件。
旧版本至少保留十四天，保护 current、当前之前最近版本、语义版本最新三个，以及恢复证明指定的回滚版本。
备份至少十四天、至少三套完整集，保护最新成功指针、最新实际恢复点及回滚依赖。
缺少可信恢复/回滚证明时，版本与备份清理关闭。

预览绑定账号、五分钟期限、所选实物指纹及保护集合。删除同时持有运维锁和 updater 锁；
配套备份还持有正式 `.backup.lock`。有预约或执行中的更新时拒绝清理。
删除前先保存 RUNNING 意图，再重新核对固定根、所有者、链接/挂载边界、文件是否在用、内容指纹和保护状态，全部隔离核对后才 unlink。
中断先保留持久意图和隔离项，不自动重放。隔离残留会在列表显示，并阻止后续清理，交主机管理员核对。

## root 恢复证明登记

仅主机 root CLI 可调用 `record-restore-proof`；Unix RPC 与 HTTP 都不暴露此操作。必须先完成真实隔离恢复、
核对目录、数据与文件，并保存验收回执，不能拿完整性校验输出冒充。root stdin 结构如下（占位文本不能直接提交）：

```json
{
  "proof": {
    "kind": "PAIRED_BACKUPS",
    "resourceName": "<固定备份根中的集合名>",
    "manifestSha256": "<原始manifest的SHA256>",
    "dumpSha256": "<原始dump的SHA256>",
    "verifiedAt": "<带时区且不在未来的实际验收时间>",
    "restoreExitCode": 0,
    "sourceVersion": "<实际备份时的应用版本>",
    "flywayVersion": "<来源schema版本>",
    "flywayCount": 790,
    "verificationMethod": "ISOLATED_POSTGRES_RESTORE",
    "restoreReceiptSha256": "<真实验收回执的SHA256>",
    "restoredFlywayVersion": "<必须与来源schema相同>",
    "restoredFlywayCount": 790,
    "restoredFlywayFailed": 0
  },
  "requiredReleaseVersions": ["<当前运行及回滚所需版本>"],
  "requiredRollbackResources": []
}
```

`flywayCount` 是示例数量，实际提交必须使用本次来源与恢复结果。升级前独立 dump 使用
`PREACTIVATION_BACKUPS`，不提供 manifestSha256，其它恢复证据同样必需。
登记器在共同锁、正式备份锁内复核确切 manifest/dump 哈希及当前版本，原子写 root `0600` 注册表；
同名实体不同哈希禁止覆盖。旧证明历史不使已删除且不再需要的备份重新成为依赖。
正式配套备份自动保留读取同一注册表，防止绕过页面保护删除恢复点。

固定目录由每家公司主机安装时填写 `/etc/uten-imp/operations.json`；默认示例在
`operations.example.json`。调整主机路径必须同时核对实际挂载、正式备份配置和 systemd 写范围，
不能把本接口变成任意文件浏览器。
