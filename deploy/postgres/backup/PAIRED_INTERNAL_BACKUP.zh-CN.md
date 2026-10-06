# 数据库与内部文件的配套备份

`paired_internal_backup.py` 生成一套可配对恢复的数据库和内部文件副本，放在
`/data/uten-imp-backups/paired`。它不向阿里云发送文件，也不替代现有 pgBackRest、
WAL 归档或异机数据库灾备。当前数据库和该备份目录都在 HDD 阵列上：同机副本不等于异机灾备。

2026-09-30 起新备份使用 `uten-paired-internal-v2`，同时收集 `CLEAN` 附件、客户报价模板候选/版本
及 `goods_cost_imports` 的私有原件引用。旧 v1 备份仍可用同一程序 `--verify` 校验；v1 不含独立
私有文档清单，不能据此声称已备份成本导入原件。无需修改既有 Flyway 文件或业务对象 provider。

## 一致性依据

已退役的日常备份实现在数据库导出后才执行 `rsync --delete`；期间删除文件
可能使数据库快照仍引用已被删除的原件。其 rsync 失败只输出警告，却仍删除旧数据库备份，
所以不能把旧脚本的成功当作启用内部附件后的完整恢复证明。旧入口 `uten-backup-daily` 及其 `uten-backup.{service,timer}` 已于 2026-10-06 从仓库删除 (服务器上按整改计划同步删除)，现役单元只有 `deploy/simple/units/uten-paired-internal-backup.{service,timer}`。部署需先安装 Python helper、依赖和 root-only 配置；配置缺失时直接失败。

新脚本使用 PostgreSQL `REPEATABLE READ` 事务，按 UUID 顺序对快照中的 `CLEAN` 附件行
加 `FOR SHARE` 锁。系统的正常删除先在同一事务更新附件为 `DELETE_PENDING` 并写入
`DELETE_FINAL` outbox，后台只有看到已提交意图才会删文件，因此这些行锁保护备份期间的原件。
孤儿清理另有对象锁及引用复核，仍被附件引用的对象不会合法进入孤儿删除队列。
脚本在加锁前和读取完全部已锁行后检查 `CLEAN` 与待执行删除队列，发现冲突就整次失败。
如果取锁时原行已改变，PostgreSQL 的 `40001` 同样导致整次失败，不发布部分成功。

v2 对存在的三张私有文档表也按 UUID 加行锁，核对统一私有引用视图完整性，并对全部引用执行
精确 provider/key/version 删除队列冲突检查。只读取元数据，不读取名称、预览或工作簿字段。
同一物理路径的重复引用只复制一次，所有逻辑引用保留在 `references.jsonl`；版本、原始大小、
摘要或存储元数据相互冲突时整次失败，禁止按任意一行覆盖另一行。

所有已确认内部文件按不可变对象键复制，并校验 57 字节封装、压缩类型、存储大小、
原始 SHA-256、原始字节数和数据库版本身份；再以同一事务导出的 snapshot 执行 `pg_dump`。
事务一直保留到导出成功才释放文件删除锁。新上传、新单据和普通读取不需要这些锁，可以继续；
删除已确认附件可能等待本轮备份，时间上限默认 30 分钟。并发变更、坏文件、缺文件、未知或
非 internal/local 的 CLEAN provider、空间不足、超时或中断均失败，旧成功集和旧成功指针保持可用。

每套目录包含 `database.dump`、`media/final/`、逐件 `objects.jsonl` 和 `manifest.json`。
v2 另有 `references.jsonl`，`clean_objects` 仍表示 CLEAN 附件引用数，`private_document_references`
表示私有文档引用数，`media_objects` 才是去重后的物理文件数。internal 封装文件仍在 `media/final/`；
local 裸文件在 `media/local/final/`，按数据库原始大小和 SHA-256 校验，local 版本必须为空。
若有 local 引用，配置必须增加 `local_media_root`，与应用的显式绝对 `UTEN_STORAGE_LOCAL_DIR`
一致且与 internal 根及备份根互不包含；缺少该配置直接失败，不能把裸文件当成 internal 封装。
私有清单记录真实业务 UUID、对象键、provider、编码、原始/存储 SHA 和大小；整体清单记录
数据库版本、快照信息、耗时、文件数量、占用量和资源限制。目录及清单均同步到磁盘后原子
发布；最后才更新 `latest-success.json`。`.incomplete-*` 是失败证据，不是可恢复的成功集。
旧集按下节「自动保留」规则在每次成功后清理；人工处理历史目录时仍禁止全目录盲删。

## 自动保留 (默认 3 天)

2026-10-05 起，每次备份**发布成功并写好 `latest-success.json` 与 `last-attempt.json` 的 SUCCESS 之后**，
同一进程在仍持有单任务锁时清理旧集。规则全部是保守方向：

- 保留期 = 配置项 `retention_days` (默认 3，2026-10-06 用户定的口径：服务器上所有备份只留 3 天；只接受 1..365 的整数；`"3"`、`3.0`、`true`、0、366 等
  非法值在启动校验时直接失败并记 FAILED，不会悄悄放宽或关闭清理)。一份完整集合**同时满足两条**
  才删除：(1) 早于服务器本地时间最近 N 个日历日 (含当天)；(2) 不在时间最新的 N 份完整集合之内。
  定时器每天 03:40、13:10 各跑一次，N=3 时 10-06 13:10 运行后留 10-04..10-06 共 6 份，10-03 及更早删除。
  年龄只看集合名里自带的 UTC 时间戳换算成本地日期，**不看目录 mtime**。
- 第 (2) 条是数量下限 (与 pgBackRest `repo-retention-full=3` 按份数保留同理)：连续失败多天后
  第一次成功、或系统时钟向前跳了很多天时，不会把历史一次删到只剩当次 1 份。例如 10-07..10-13
  全部失败、10-14 恢复成功，会保留 10-14 这份与失败前最后 2 份；时钟前跳 30 天只多删最旧的几份，
  不会少于 3 份。时钟回拨不会误删 (未来日期不算过期)。手工补跑会多出 1 份，3 天后自然回落。
- 只有同时满足以下条件的目录才算可删的完整集合：名称严格为 `YYYYMMDDTHHMMSSZ-12位小写十六进制`
  且日期真实存在；是 `backup_root` 下一层的真实目录 (非符号链接/junction)，属主与 `backup_root`
  相同；自带 `manifest.json` (逐级 NOFOLLOW 打开、不超过 64KiB)，其 `format` 为 v1/v2、`set_id`
  等于目录名、`completed_at` 带时区。任何一项不符的目录记为 `unrecognized`，永不删除。
- 永远保留：本次刚发布的集合、`latest-success.json` 指向的集合、时间戳最新的完整集合。
  本次集合或成功指针任一无法确认为完整集合时整轮跳过，一个都不删 (所以成功集合不足 1 份时不会删)。
- 失败/中断留下的 `.incomplete-<set-id>` 目录，只按日历日规则 (不受数量下限保护) 和同样的
  名称/真实目录/属主规则清理；
  未满保留期的失败目录继续保留作为证据。其它文件 (`last-attempt.json`、`.backup.lock`、`.latest-*`、
  `.attempt-*`) 和任何未知名称一律不碰。
- 删除时先把目录原子改名为 `.expired-<set-id>` 移出已发布命名空间，再用不跟随链接的
  `shutil.rmtree` 删除 (Linux 下为基于目录 fd 的防链接实现，否则拒绝删除)；中途被打断时，下次成功运行
  会先完成残留的 `.expired-*`。目录内的符号链接只删链接本身，绝不进入链接目标；删除前再次核对
  解析后的路径位于 `backup_root` 内。
- 删除前后各写一行结构化日志到 journal (stderr)：`paired_backup_retention_plan` 列出保留指针、最新集合、
  待删集合、待删失败目录和无法识别的目录；`paired_backup_retention_done` 列出已删集合与各自字节数、
  `freed_bytes`、失败项和剩余完整集合数；整轮跳过记 `paired_backup_retention_skipped`。
- 清理中的任何异常 (含单个目录删除失败、收到 SIGTERM) 只记 `paired_backup_retention_failed` 或
  `failed` 项，不改变本次已经记录的 SUCCESS，也不影响退出码；失败的目录下次成功运行再处理。
  备份失败时根本不进入清理。
- 程序没有单独的「只清理」命令行入口，清理只能由一次完整成功的备份触发。

### 清理结果进监控 (不只写日志)

`last-attempt.json` 在 SUCCESS 时多一个只含计数的 `retention` 对象 (不含集合名、路径或异常文本)：
先写 `{"status":"PENDING"}`，清理结束后改写为 `APPLIED`、`SKIPPED` 或 `FAILED`，并带
`retentionDays`、`completeSets` (清理后剩余完整集合数)、`removedSets`、`removedUnpublished`、
`failedDeletes`、`unrecognizedEntries`、`freedBytes`。改写失败时保持 PENDING，并记
`paired_backup_retention_state_unwritten`。

`deploy/monitoring/server_status_export.py` 只读这个文件，备份本身成功但出现下列任一情况时，
发布 `lastAttemptStatus=CHECK_FAILED` (系统设置-服务器状态页显示红色「最近一次备份检查未通过」，
最近成功时间照常显示)：

| reason | 触发条件 |
|---|---|
| `PAIRED_RETENTION_UNPROVEN` | 没有 `retention` (例如仍是不清理的旧脚本)、字段非法、或 PENDING 超过 35 分钟 (单元超时上限，说明清理进程已不在) |
| `PAIRED_RETENTION_NOT_APPLIED` | `SKIPPED`/`FAILED`、`failedDeletes` 或 `unrecognizedEntries` 大于 0、`completeSets` 为 0 或超过 `4 × retentionDays` |

PENDING 在 35 分钟内只显示「未知」(reason `PAIRED_RETENTION_RUNNING`)，与备份运行中一致。
集合数上限取 `4 × retentionDays` (= 每天 2 次 × 2 倍余量)：正常每天两份最多 2N 份，再留同样多的
手工补跑余量，避免补跑几次就报红；清理逻辑若悄悄失效，最多 N 天后也会报红。

查看最近一次清理：`journalctl -u uten-paired-internal-backup.service -n 50 | grep retention`。
该规则只管本目录的配套备份；pgBackRest (`repo1/repo2-retention-full=3`) 和更新器升级前 dump
(`UTEN_BACKUP_KEEP_DAYS=3`) 各自保留，见 [简化发布链 Runbook](../../simple/RUNBOOK.zh-CN.md)「备份布局与保留」。

## 安装前核对

这些文件是发布候选，不代表已经在公司服务器安装或通过验收。

1. 核实实际挂载、文件系统和剩余空间。在线文件建议目录是
   `/var/lib/uten-imp-media/attachments`，下分 `staging/final/scratch`；备份目标必须独立于在线根目录。
2. 服务器需要 `python3`、`python3-psycopg2` 和与服务器同主版本的 PostgreSQL 16 客户端。
   运行前验证版本与 Unix socket 的本机 postgres peer 登录；本脚本不假装这些依赖已安装。
3. 脚本安装为 root 拥有、0755；配置安装为 `/etc/uten-imp/paired-internal-backup.json`、root:root、0600。
   先创建备份专用目录 root:root 0700。程序以 root 管理私有文件，连接时临时切换 postgres
   有效 UID，`pg_dump` 子进程也以 postgres 身份使用同一 peer 连接；不在配置中保存密码。
4. 现役单元是 `deploy/simple/units/uten-paired-internal-backup.{service,timer}` (2026-10-06 从
   `deploy/systemd/*.example` 迁来，那两份样例已删除)，安装前核实路径。默认单并发 (进程文件锁 + oneshot unit)，
   CPU 0.5 核、内存高水位 384MiB/上限 768MiB、整组 HDD 读写各 20MiB/s、低 I/O 权重。
   文件复制另有 20MiB/s 软件限制；最低保留空间为 10GiB 与容量的 15% 中较大者。
   大数据库导出也受同一 cgroup 预算限制，必须用实际负载确认耗时和业务延迟。
   该限制直接约束备份进程、pg_dump 的读写和文件复制，不直接限制 PostgreSQL 服务进程
   为查询执行的缓存读取、解压和扫描；导出写入的背压会降低持续导出速率，但不能据此承诺
   数据库物理扫描始终不超过 20MiB/s。首次执行必须监测业务延迟，必要时降低限额或另选时段。
5. 定时每天两次：03:40 与 13:10 (避开 02:17 pgBackRest 与周日 05:00 更新器)；13:10 落在营业时段，
   依赖上面的 cgroup 限速，首次启用当天观察业务延迟。旧 01:30 rsync 任务已退役删除。
6. 配置里可选 `retention_days` (缺省即 3)。旧版脚本不认识该键和 `local_media_root`，会以
   `TypeError` 拒绝整个配置；必须**先装新脚本，再改配置**。监控导出脚本要在新备份脚本成功跑过
   一次之后再装，否则旧脚本的记录没有 `retention`，状态页会按设计报红。
7. 从 v1 脚本 (2026-09-09 安装版) 升级到 v2 前，先只读核对私有文档引用：`PRIVATE_TABLES` 五张表
   (含 `goods_cost_imports`、`ai_input_originals`) 里 `storage_provider='local'` 的行要求配置 `local_media_root` (与应用
   `UTEN_STORAGE_LOCAL_DIR` 相同，下有 `final/`)，且每个被引用的原件都必须真实存在、大小和 SHA-256
   一致；缺一个文件整次备份就失败，保留清理也不会运行。先处理掉孤儿引用再升级。
8. 服务器上不留旧脚本或配置的副本。现装 v1 (sha256 `cc97e795...`) 是提交 `1516ad9a8` 的
   `paired_internal_backup.py` 按 CRLF 换行保存的版本 (换成 LF 后 sha256 `d779b514...` 与该提交
   一致)，回退时从 git 取该提交版本即可；配置回退只需删掉新增的两个键。传文件到服务器时先写临时名，
   在服务器上用 `sha256sum -c` 核对本地摘要通过后再 `mv` 到正式路径，不通过就删临时文件。

## 校验和恢复

执行 `python3 paired_internal_backup.py --verify /data/uten-imp-backups/paired/<set-id>`
会重新核对 dump 摘要、对象清单、所有封装和解压后的原件，失败返回非零。
这一步不能替代 PostgreSQL 真正导入和应用下载验收。

恢复时先停止目标应用、附件删除 worker 和定时任务，并保存目标现有备份。
在隔离空数据库中用匹配版本 `pg_restore --exit-on-error` 导入该套 `database.dump`；角色由现有
部署制度准备，不能用 `--clean` 对不明现库盲目覆盖。把同一套 `media/final` 复制到新的空媒体根
下，创建空 `staging/scratch`，核对全部清单和目录 fsync，再按运行账户恢复 0700 文件目录权限。
数据库中的 CLEAN 元数据必须与该套对象清单 UUID/版本/大小/SHA 全量相符，禁止混用不同日期
的数据库和文件。先离线验证，之后启动应用，以原有权限试下载并逐字节比对原件。

v2 恢复须同时恢复 `media/local/final/` 到独立的 local 根，并创建对应 `staging/`。
在恢复库中调用 `collect_references(cursor, lock=False)`，再将结果作为 `verify_media` 的第三个参数，
证明恢复库所有附件及私有文档引用与配套清单完全一致。`--verify` 仅证明备份文件内部完整性，
不能代替这一步恢复库比对。任何已有同键文件只可在 provider、版本、原始和物理大小/摘要均一致时复用；
不一致必须停下处理，禁止覆盖现有对象，也不自动清理未引用的旧对象。

未确认上传不属于已发布业务文件，恢复后需重新上传；`DELETE_PENDING/DELETE_FAILED` 的文件
不在 CLEAN 配对范围内，其既有精确删除队列可以幂等处理文件不存在。恢复验证完成前不启动
孤儿清理。业务单据软删除保留的审计附件仍在备份范围，只要其附件元数据是 CLEAN。

最终验收必须记录实际数据库、文件数、总字节、hash、恢复查询和下载结果，以及备份期间业务
延迟；已有底层存储/冷恢复测试不能代替这个新脚本的并发和整套恢复验证。

## 本地脚本验证

本次在断网 Linux 容器、PostgreSQL 16.15、真实磁盘 fsync、1 核/768MiB 容器限额下运行
`test_paired_internal_backup.py`，9 项全部通过、无跳过。其中 8 项使用隔离真实数据库：
导出/`pg_restore`/原件冷复制恢复、删除等待与新上传并发、40001、中断、空间不足、文件损坏、
缺失、异常 provider、矛盾删除队列、单任务锁和清单校验；另 1 项检查实际 Java 删除链的事务顺序。
并发测试执行与服务一致的 PostgreSQL 删除意图语句及提交后物理删除，不是启动完整 Java 应用。
恢复同时核对两种存储编码原件和 `123.12345678` 精确业务值。实际 CLI 收到 SIGTERM 后旧成功
指针保持不变、数据库锁释放。证据在 `.codex-tmp/paired-backup-20260909/linux-tests-final.log`。
该测试尚未使用公司整库/真实附件卷，也没有证明公司 systemd I/O 限速或公司负载下的响应时间。

2026-10-05 自动保留另有 `test_paired_backup_retention.py` (真实临时目录，不用数据库)：超期删除与
最近 N 个日历日保留 (2026-10-06 起另验证出厂默认 3 天、每天两次时恰好留 6 份)、按名称时间而非 mtime、成功指针与最新集合保护、指针/新集合无法确认时整轮不删、
非法名称/无清单/清单不符/普通文件不删、符号链接与 junction 不跟随不删除、`backup_root` 外路径
与链接根目录拒绝、`retention_days` 校验、单个删除失败继续其余且留 `.expired-*` 下次完成、失败目录
保守清理；Linux root 下另验证真实 `backup()` 入口成功后清理、清理异常不改 SUCCESS、备份失败不清理。
`test_paired_internal_backup.py` 新增一项真实 PostgreSQL 16 备份连跑两次，验证第二次成功后只删除
自己的过期集合与失败目录、保留未知目录，且非法 `retention_days` 记 FAILED 并保留全部集合。
本机 Windows 与断网 Linux 容器 (PostgreSQL 16.15，root 与非 root 各一轮) 均通过。

同日复审补充 (当时默认 7 天)：数量下限 (连续失败一周后首次成功保留 7 份、时钟前跳 30 天只删 1 份)、清理结果计数
写入 `last-attempt.json` (APPLIED/FAILED/SKIPPED/写不进去保持 PENDING)，以及
`deploy/monitoring/test_server_status_export.py` 的保留告警判定 (无证据、跳过、失败、未知目录、
集合数越界报 CHECK_FAILED，清理进行中只报未知)。断网 Linux 容器 root 一轮 `deploy/postgres/backup`
196 项、`deploy/monitoring` 66 项全过；非 root 一轮同样通过 (需要 root 的项跳过)。
