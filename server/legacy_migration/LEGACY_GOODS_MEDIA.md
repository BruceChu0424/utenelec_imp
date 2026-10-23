# 旧货品原图的保全与附件导入

八个旧图片列必须逐列盘点，不能沿用“图纸列不迁”的历史假设。本次物理只读快照 `YTDQ_rehearsal_20261022` 的 35,752 个货品中，只有旧 ID 65184、原码 280245037 的两个列有原件：

|旧列|原始字节|SHA-256|目视结果|
|---|---:|---|---|
|ProductGraph1|195757|0245ee9001a0418ee299220c5a6efbfa25892cede319da5bdfb6f8663507edcc|同一开关正面产品照片|
|GroundGraph|58888|31675b36b7a20518c1e02acc27553964a50df8d1c406823d251d62f295a82232|同一开关背面产品照片|

其余六列非空计数为零。两张归入 GOODS 附件的“产品图片”，保留原始 JPEG，不缩放、不转码、不据列名假定为图纸。首次在数据库尚未物理封存时生成的 receipt 保留为历史；最终 receipt 来自明确 `READ_ONLY` 状态，并与首次原件逐字 SHA 相同。

## 重复执行

先按主彩排流程恢复、物理只读封存旧库并完成 All 导出，再提取原件。脚本只做 SELECT，在 Serializable 事务内读取，结束回滚；不修改任何数据库。

```powershell
powershell -NoProfile -File server/legacy_migration/export_legacy_goods_media.ps1 `
  -OutputDir D:/uten_legacy_rehearsal/20261022/legacy-media `
  -SourceExportManifest C:/Users/bruce/.codex/worktrees/legacy-import-rehearsal/uten_imp/server/legacy_migration/data/export_manifest.json
```

确认官方 ClamAV 镜像摘要，拉取镜像并创建仅存病毒库的 Docker volume。病毒库更新容器没有用户文件挂载；扫描容器没有网络，原件和病毒库均只读挂载。使用[官方 ClamAV Docker 镜像](https://docs.clamav.net/manual/Installing/Docker.html)和[官方扫描说明](https://docs.clamav.net/manual/Usage/Scanning.html)，不上传原件到第三方。

```powershell
docker pull clamav/clamav:stable
docker image inspect clamav/clamav:stable --format '{{index .RepoDigests 0}}'
docker volume create uten-legacy-rehearsal-20261022-clamav-db
# 先正常编译当前后端。dependency:build-classpath 不会启动后端或连接数据库。
mvn -f server/pom.xml dependency:build-classpath '-Dmdep.outputFile=D:/Projects/uten_imp/.local-tmp/legacy-media-classpath.txt' -q
python server/legacy_migration/prepare_legacy_goods_media.py `
  --media-manifest D:/uten_legacy_rehearsal/20261022/legacy-media/legacy_goods_media_manifest.json `
  --source-export-manifest C:/Users/bruce/.codex/worktrees/legacy-import-rehearsal/uten_imp/server/legacy_migration/data/export_manifest.json `
  --storage-root D:/uten_legacy_rehearsal/20261022/sealed/storage `
  --output-dir D:/uten_legacy_rehearsal/20261022/sealed/legacy-media-import `
  --server-classes D:/Projects/uten_imp/server/target-v904-material-identity/classes `
  --classpath-file D:/Projects/uten_imp/.local-tmp/legacy-media-classpath.txt `
  --target-database uten_imp_rehearsal_20261022_v2 `
  --clamav-image clamav/clamav@sha256:e19130cdebaeacc71fa46eab3ed6f69941f2f22aa5e08d55e9197f8edf43ce5e `
  --clamav-db-volume uten-legacy-rehearsal-20261022-clamav-db
```

下次正式导入必须使用当时重新核验的官方镜像及新病毒库，不能把本次扫描当作新文件的证明。新增原件会因缺少目视分类审核而停止，审核后显式补充映射。若扫描不可用、超时、有检测或漏扫，脚本失败，不产生伪造 CLEAN。

## 存储与数据库边界

Java 离线桥直接复用 `AttachmentContentInspector`、`LocalDiskStorageService` 和 `AttachmentDownloadVerifier`。独立 root 下只建立标准 `staging/`、`final/` 命名空间；本地开发 provider 不需要 internal 生产存储 identity bootstrap。存储键为稳定不透明 UUID；同键不同字节拒绝覆盖。对象通过类型、图像尺寸、原始大小和 SHA 检查后提升并复读验证，随后仅清理该原件的 staging 副本。

本地合同为 `storage_provider=local`、`storage_version=NULL`、`storage_etag=NULL`、`storage_encoding=IDENTITY`、`stored_size_bytes=size_bytes`。不能伪造 internal 版本号或手写 internal envelope。最终后端必须显式配置：

```powershell
$env:UTEN_STORAGE_PROVIDER='local'
$env:UTEN_STORAGE_LOCAL_DIR='D:/uten_legacy_rehearsal/20261022/sealed/storage'
```

保留现有附件上传开关和权限，不改密码，不生成登录 token。旧主库 storage root 保持原样。服务端文件下载仍受附件读取权限、goods:view 和货品可见性控制；读取扫描后的旧照片不要求重新开放上传。

`goods_legacy_media_manifest.json` 的 generator、inputs、evidence_sources、outputs 均带 SHA；原图、最终对象、真实扫描日志/引擎/签名库哈希、标准适配器源码/实际 class/桥接 class 和 CSV/SQL 均可追溯。先验证辅助层，再由总协调器复制固定 `goods_legacy_media.csv` 到执行容器 `/tmp/`。

`goods_legacy_media.sql` 由调用方同一事务执行，要求当前数据库全名、当前 BOOTSTRAP run、run 的 `reconciliation_summary.rawManifestSha256`、原备份 SHA 和保留管理员 actor 都匹配。由旧 ID 及原业务码在新 goods 中解析当前 UUID，不引用旧 UUID。CSV 必须与 SQL 内封存的已扫描行完全相同。只新增精确 GOODS 附件和导入核对摘要；不创建上传会话，不修改已有不可变附件。幂等重试使用同一封存 CSV/SQL，不能重扫后修改已入库的扫描身份。

## 验证边界

2026-10-22 本地实际 ClamAV 1.5.4 / daily 28161，3,628,191 病毒特征；断网扫描两张原件，逐件 OK，Scanned files=2 / Infected files=0。扫描后的标准适配器和应用下载校验器已复读每张原图并验证 SHA。真实 PostgreSQL loader 测试在独立临时容器中执行，不连接开发业务数据库。

总协调器仍需在整批导入后核对两条附件的 GOODS UUID、列来源、字节 SHA、scan 元数据和原件计数，并以真实用户登录检查货品页面列表/预览/下载及无权限拒绝。离线适配器验证不代表浏览器和真实用户权限验收完成。
