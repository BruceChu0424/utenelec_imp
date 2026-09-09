# 数据库与内部文件的配套备份

`paired_internal_backup.py` 生成一套可配对恢复的数据库和内部文件副本，放在
`/data/uten-imp-backups/paired`。它不向阿里云发送文件，也不替代现有 pgBackRest、
WAL 归档或异机数据库灾备。当前数据库和该备份目录都在 HDD 阵列上：同机副本不等于异机灾备。

## 一致性依据

旧 `deploy/simple/uten-backup-daily.sh` 在数据库导出后才执行 `rsync --delete`；期间删除文件
可能使数据库快照仍引用已被删除的原件。其 rsync 失败只输出警告，却仍删除旧数据库备份，
所以不能把该脚本的成功当作启用内部附件后的完整恢复证明。

新脚本使用 PostgreSQL `REPEATABLE READ` 事务，按 UUID 顺序对快照中的 `CLEAN` 附件行
加 `FOR SHARE` 锁。系统的正常删除先在同一事务更新附件为 `DELETE_PENDING` 并写入
`DELETE_FINAL` outbox，后台只有看到已提交意图才会删文件，因此这些行锁保护备份期间的原件。
孤儿清理另有对象锁及引用复核，仍被附件引用的对象不会合法进入孤儿删除队列。
脚本在加锁前和读取完全部已锁行后检查 `CLEAN` 与待执行删除队列，发现冲突就整次失败。
如果取锁时原行已改变，PostgreSQL 的 `40001` 同样导致整次失败，不发布部分成功。

所有已确认内部文件按不可变对象键复制，并校验 57 字节封装、压缩类型、存储大小、
原始 SHA-256、原始字节数和数据库版本身份；再以同一事务导出的 snapshot 执行 `pg_dump`。
事务一直保留到导出成功才释放文件删除锁。新上传、新单据和普通读取不需要这些锁，可以继续；
删除已确认附件可能等待本轮备份，时间上限默认 30 分钟。并发变更、坏文件、缺文件、未知或
非 internal 的 CLEAN provider、空间不足、超时或中断均失败，旧成功集和旧成功指针保持可用。

每套目录包含 `database.dump`、`media/final/`、逐件 `objects.jsonl` 和 `manifest.json`。
私有清单记录真实业务 UUID、对象键、provider、编码、原始/存储 SHA 和大小；整体清单记录
数据库版本、快照信息、耗时、文件数量、占用量和资源限制。目录及清单均同步到磁盘后原子
发布；最后才更新 `latest-success.json`。`.incomplete-*` 是失败证据，不是可恢复的成功集。
脚本不会删除旧集或失败目录；维护人员核对保留需求和空间后再明确清理，禁止全目录盲删。

## 安装前核对

这些文件是发布候选，不代表已经在公司服务器安装或通过验收。

1. 核实实际挂载、文件系统和剩余空间。在线文件建议目录是
   `/var/lib/uten-imp-media/attachments`，下分 `staging/final/scratch`；备份目标必须独立于在线根目录。
2. 服务器需要 `python3`、`python3-psycopg2` 和与服务器同主版本的 PostgreSQL 16 客户端。
   运行前验证版本与 Unix socket 的本机 postgres peer 登录；本脚本不假装这些依赖已安装。
3. 脚本安装为 root 拥有、0755；配置安装为 `/etc/uten-imp/paired-internal-backup.json`、root:root、0600。
   先创建备份专用目录 root:root 0700。程序以 root 管理私有文件，连接时临时切换 postgres
   有效 UID，`pg_dump` 子进程也以 postgres 身份使用同一 peer 连接；不在配置中保存密码。
4. 安装两份 `.example` systemd 单元前核实路径。默认单并发（进程文件锁 + oneshot unit），
   CPU 0.5 核、内存高水位 384MiB/上限 768MiB、整组 HDD 读写各 20MiB/s、低 I/O 权重。
   文件复制另有 20MiB/s 软件限制；最低保留空间为 10GiB 与容量的 15% 中较大者。
   大数据库导出也受同一 cgroup 预算限制，必须用实际负载确认耗时和业务延迟。
   该限制直接约束备份进程、pg_dump 的读写和文件复制，不直接限制 PostgreSQL 服务进程
   为查询执行的缓存读取、解压和扫描；导出写入的背压会降低持续导出速率，但不能据此承诺
   数据库物理扫描始终不超过 20MiB/s。首次执行必须监测业务延迟，必要时降低限额或另选时段。
5. 默认定时 03:40，与旧 01:30 任务分开；启用前对比所有 pgBackRest、WAL 和维护时段。
   旧 rsync 定时任务只有在新整套恢复验收完成后才单独停用，不修改 pgBackRest/repo2 制度。

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
