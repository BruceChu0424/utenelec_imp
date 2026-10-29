# 混合运行时备份与恢复

由唯一进度登记表生成。

## W7-BACKUP-001

- [ ] **历史/新family元数据合同** — 本机验证/待本项最终验收

影响：`backend`；负责人：Codex；依赖：W7-DIST-001。

源入口：`deploy/postgres/backup/client_release_state_backup.py`。

完成条件：

1. 旧缺/null解释flutter，WPF mode/kind/arch严格，原metadata bytes不重写。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/software-download-publish-20261028.json`。

接续/限制：E006：新增系统/目标、独立发布与交付合同当前源码通过本机回归；完整目标机、生产分发及本项最终DoD仍未验。。

## W7-BACKUP-002

- [ ] **双运行时包字节冷恢复** — 源码已实现/待整合验证

影响：`delivery`；负责人：待认领；依赖：W7-DIST-001。

源入口：`deploy/postgres/backup/client_release_state_backup.py`。

完成条件：

1. 两arch双包/历史记录导出核验恢复原字节、SHA与审计身份一致。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-BACKUP-003

- [ ] **withdrawn/tombstone不复活** — 源码已实现/待整合验证

影响：`delivery`；负责人：待认领；依赖：W7-DIST-001。

源入口：`deploy/postgres/backup/client_release_state_backup.py`。

完成条件：

1. sha=null/size0及残留字节规则正确，旧记录保留且不给已清理包下载。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-BACKUP-004

- [ ] **锁/并发/已有目录拒绝** — 进行中

影响：`delivery`；负责人：Codex；依赖：W7-DIST-001。

源入口：`deploy/postgres/backup/client_release_state_backup.py`。

完成条件：

1. 真实POSIX+JavaFileChannel互锁、恢复仅新空目录、活动上传/备份不互毁。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-BACKUP-005

- [ ] **现场备份恢复与回滚回执** — 未开始

影响：`delivery`；负责人：待认领；依赖：W7-DIST-001。

源入口：`deploy/postgres/backup/client_release_state_backup.py`。

完成条件：

1. 配套集合/目录/版本/权限/锁和下载实测；无现场回执不报部署成功。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。
