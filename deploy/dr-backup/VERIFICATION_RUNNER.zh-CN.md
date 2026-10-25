# 公司侧真实恢复执行器与 latest 证明续期

这是显式 opt-in 的运维组件。默认 small（PGDATA 2GiB / memory 3GiB）、普通 bundle 600 秒、history 7/30 与公司本地双仓 14 天均不变。公司 root 部署、验收后才启用周任务；代码/单测通过不等于新 7.1m 行库或四小时 RTO 已验收。

## 角色与不可变边界

- 云端只放 ciphertext、source 签名和脱敏恢复证据；没有恢复私钥、口令或业务 PGP/HMAC/JWT。旧 sender key 的 put/status 权限不扩。
- 新建独立 verifier SSH key，由公司 root 的 encrypted credential 持有。云端沿用现有 22，只能执行固定 `verification-forced.sh`：`restrict,command="/usr/local/libexec/uten-imp-dr-backup/verification-forced.sh"`。禁止 pty、agent、X11、所有 forwarding；不复制 cloud 管理员私钥、不开放新 listener。
- verifier host 的 root、固定源码和配置是信任前提。SSH 鉴别该受信操作角色，不是硬件远程证明。普通应用用户、上传 key 与 publisher 不能签发或刷新 commissioning。
- 私钥导入临时 `/run` 私有 GPG home，口令只读 credential/RAM/memfd；不用 argv、环境变量值、日志或 Git 传秘密。公司 root 持有新备份代次的恢复能力是本用途的明确安全边界；独立 PC escrow 保留，物理离线副本须另做，不能称已 airgap。
- 真实 restore/全部原件、核心 PGP/HMAC、实际 AI 解密和 current issuer 校验通过后，才按此次 point/report/config SHA 生成现有正规 credential-review。普通 drill 的 `knownAncillaryCredentialIssuesCleared=false` 保持原义，不改 true。
- 外部凭据检查是材料可恢复、非占位与库存检查。执行器不调用外部 API，不能把 `VERIFIED` 解释为短信、AI 或外部 API 可用。

## 固定预算与资源

`large-memory`：PGDATA tmpfs 12GiB、容器 memory 14GiB、swap 0；实时 host MemAvailable 与每个可见父 cgroup 的剩余量都须至少 18GiB。任一控制器不可观测或不足便拒绝，没有绕过参数。容器固定 UID/GID 999、全 capability 0、NNP=1、readonly rootfs、network=none、无 host/生产 mount、pids=100；实际 PostgreSQL 必须 16。镜像 fully-qualified official Debian16 tag/digest 与该 runtime 的实际 image ID 分别固定，`--pull never`。

下载预算显式 30..10800 秒，整个不可续期 point lease 最长 14400 秒；示例 10800 download + 3300 restore + 300 cleanup/登记 = 14400。restore 内仍留 30 秒清理余量。1Mbps 的大包必须实测，超时失败保旧，不能因设置 10800 就声称传输/RTO 达标。

同一 SSH 双向会话持有真实 FD flock，覆盖 download EOF 后的恢复、credential review 与 commission。GC 识别同一 immutable point/hash marker；正常新 snapshot 继续发布时，只临时保演练点与当前点。无 renew 指令，断线、signal、超期关闭 FD。完整登记后释放租约再 GC，回到一根；quota/minfree 原硬限不变。

大 profile 与自动任务使用一个本机 admission lock。带本 instance UUID、PID/start/boot 标签且旧进程已死亡的隔离 clone 可精确回收；不按模糊名称 stop/remove，不碰 5434 或其他导入容器。元数据/label 不明时失败等待 Root 审查。

## 安装前置（Root 执行，非自动安装脚本）

1. 保留旧链、原配置及精确 SHA/inode。Root-Data 唯一写入者与最终 schema/cutover 协议继续有效；不为恢复测试改生产数据库。
2. 无 Docker 的公司机可用官方发行版 Podman CLI。先安装本仓受审 needrestart list-only 策略并读回，再 `NEEDRESTART_MODE=l apt-get install --no-install-recommends podman`，不全局升级。核 ERP PID/PG start time 未变，podman socket/service/autoupdate 不启用。Ubuntu24 默认 needrestart 可自动重启服务，所以这一步必须在安装前落实。[Ubuntu 官方说明](https://ubuntu.com/server/docs/how-to/software/automatic-updates/)
3. 镜像网络异常时不降 TLS、不改陌生 mirror。使用已验证官方本机镜像离线 `docker save`，核 archive SHA/config、经既有严格 SSH 传入后 `podman load`。分别保存 tag、RepoDigest、runtime ID、架构。Docker Desktop 的 manifest ID 与 Podman config ID 可能不同，不能拿一个值冒充另一个，也不能 retag 后称来自最新16。
4. 核 `findmnt -T /srv/uten-backup -o SOURCE,TARGET,FSTYPE,UUID,OPTIONS`、可用空间、已批准 UUID。挂载成功后才建立 root:root 0700 `/srv/uten-backup/dr-verification`。不能目录缺失就回落 `/tmp` 或系统盘。首次需要约 `2*bundle上限 + 2*plain上限 + 9GiB` 余量，另有独立 PGDATA RAM；这不是按600MB文件只留600MB。
5. 预建 root:root 私有 `/var/lib/uten-imp-dr-verification`、`/etc/uten-imp-dr-backup`、`/etc/credstore.encrypted`、Podman 实际 store/runroot 目录。核其真实 `podman info`，与 unit ReadWritePaths 机械相符。`/run` 目录用本组件 tmpfiles 建立，先 `systemd-tmpfiles --create`；unit namespace 前这些路径必须存在，避免再次出现 Python 尚未运行就 226/NAMESPACE。

公司和云端安装相同的固定源码 inventory（root600，脚本 shell700）：`verification_session.py`、`verification_runner.py`、`continuous_backup.py`、`snapshot_chunks.py`、`latest_snapshot.py`、`restore_drill.py`、`restore_snapshot.py`、`clone_integrity_candidate.py`、`credential_rewrap.cjs`、`prepare_ai_credential_candidate.cjs`、`uten-dr-recovery.apparmor`。另从同一 Git 提交复制 `deploy/postgres/backup/remote_recovery_catalog.py` 为该目录的同名 sibling，root600；不能遗漏 standalone 安装的这一依赖。双方计算的软件 inventory SHA 必须相同。安装根为 `/usr/local/libexec/uten-imp-dr-backup`。

### Podman4.9 的专属 AppArmor 与实际 probe

Root 先核目标不存在或是本次已知前像，再原子安装 `uten-dr-recovery.apparmor` 到 `/etc/apparmor.d/uten-dr-recovery`（root644），只 `apparmor_parser -r -W` 此文件。保留原 proc/sys/mount deny，仅同 profile 的两个精确 crun stack signal peer，以及 host `crun` 发来的 int/quit/kill/term receive。绝不改全局 crun/default、用 crun*、unconfined 或加容器 capability。[上游同型问题](https://github.com/podman-container-tools/container-libs/issues/805)

Podman 用其 `type=tmpfs,...,U=true`，不使用其4.9不接受的 uid/gid tmpfs表达。只有新内存 mount，没有 host source 可被 chown。关闭额外自动 tmpfs，明确提供 PGDATA/socket/tmp/shm。PG 官方 entrypoint 会把 socket dir chmod03775，所以 ready 后、任何 dump/key 进入前收紧回0700。ready 同时要求 PID1 comm=postgres，不能误认 initdb 的临时 server。

实际 `crun//&uten-dr-recovery (mixed)` 不伪写 enforce：还必须从 host securityfs 精确读到 own profile(enforce) 与 crun(unconfined)，核已安装 policy 字节/SHA 与当前源码相同。其他 mixed 组合拒绝。实际 kernel UID/GID、NNP、五 capsets、memory.max/swap.max、三路径 tmpfs/999:999:700 和 PGDATA capacity 都查，不能只相信 inspect。[Podman 官方参数](https://docs.podman.io/en/v4.9.3/markdown/podman-run.1.html)

## verifier.json（root600，只填实际公开元数据/路径，无秘密值）

```json
{
  "format":"uten-dr-verifier-config-v1",
  "instance_id":"<本公司固定UUID>",
  "ssh_target":"root@<既有cloud地址>",
  "known_hosts_file":"/etc/uten-imp-dr-backup/verifier-known_hosts",
  "allowed_signers_file":"/etc/uten-imp-dr-backup/source-allowed-signers",
  "recipient_fingerprint":"<从已验证新代次public descriptor取得>",
  "spool_mountpoint":"/srv/uten-backup",
  "spool_directory":"/srv/uten-backup/dr-verification",
  "runtime_directory":"/run/uten-imp-dr-verification",
  "state_directory":"/var/lib/uten-imp-dr-verification",
  "docker":"/usr/bin/podman",
  "node":"/usr/bin/node",
  "runtime":"podman",
  "postgres_image":"docker.io/library/postgres:16.15",
  "expected_image_id":"<公司本runtime实际inspect的ID，非盲套Docker Desktop ID>",
  "restore_profile":"large-memory",
  "download_budget_seconds":10800,
  "session_budget_seconds":14400,
  "restore_budget_seconds":3300,
  "proof_valid_days":28
}
```

模板占位绝不能原样启用。Root 用已经确定的 public descriptor、实际 image inspect、挂载与路径填入；不需要再向人类问已知值。known_hosts 从既有信任复制，不能运行时 ssh-keyscan/替换信任。公开 signers 文件也 root600。Node 只用现有 CJS/std crypto，不增加 pip/npm 依赖。

### encrypted credentials

Root 从已经实证的独立 vault，以二进制 stdin 供应三个 credential：`verifier-ssh-key`、`recovery-private-key`、`recovery-passphrase`，分别匹配 unit 中的精确文件。使用 `systemd-creds encrypt --name=<精确credential名> --with-key=host - <目标.cred>`；不写 SetCredential 明文，不把口令置 argv/env，不用会换行/重编码的文本管道。用 `systemd-creds decrypt --name=... <file> /dev/null` 检查 host/name 可解；真正 GPG 正确/错误口令仍由恢复验证判定。host-bound blob 不能替代独立 PC/portable escrow。[systemd255 credential 说明](https://github.com/systemd/systemd-stable/blob/v255-stable/docs/CREDENTIALS.md)

Root 部署到公司是明示的新恢复用途；云端不得收到这三者中的解密材料。新 SSH key 也不要复用 cloud admin/source sender key。不要因为忘旧密码就用新 recipient 复用旧 opaque ciphertext：新代次须有新隔离 namespace/identity、实际可解的新全点；新全点完整验收前旧链保留。

## 严格启动/验收顺序

1. timer 保持 disabled。`systemd-analyze verify` 核四 unit；机械读回 ExecStart、credential names、RequiresMountsFor、RW路径、MemoryMax/Swap、Timeout/Restart。需要变更实际 mount/store/runroot 路径时先更新准确清单，不放宽为任意 `/`。
2. 在同一受审 verification unit 建立本次私有临时 drop-in，精确重置 ExecStart 为 `verification_runner.py preflight --config ...` 并清掉 LoadCredentialEncrypted（此步没有 key/backup 输入）。实际 unit sandbox 下 probe，不能只在全权交互 shell成功就称 unit 可用。须 result0、真实16版本/镜像ID/资源/label证据与 `ownedContainerRemoved=true`，而且 ERP/生产PG未变；按SHA移除准确临时 drop-in，daemon-reload读回原 run入口。
3. 部署 source/receiver 同源新代次配置与 public recipient，source 的 `max_snapshot_plain_bytes` 必须显式2GiB内的实测值；默认512MiB仍会拒600MB dump。actual effective source snapshot unit若15min，work budget870/unit900保留余量，不把repo4min当现场值。数据库+全部原件+market/release/config总量、capture耗时与内存须实际回读。
4. 首 seed 为独立受控初始化窗口：先只运行一次新 source snapshot，签名闭包完整后暂不重复启动专用 cloud snapshot timer，避免 awaiting-commissioning 下重复大capture。公司正常本地双仓14d备份保持；old cloud 链不删，暂停/初始化期间 remote RPO不假称15min达标。
5. 首次授权 verifier key 前 Root 实证排空旧 unleased management exports；`verification-forced.sh --legacy-exports-drained` 是这项 Root 安装前提的固定承认，不是上传者参数。核 authorized_keys 的 exact forced command/restrict，先测拒绝任意远程命令/forwarding。
6. 供应 encrypted credentials，单次启动真正 `uten-imp-dr-verification.service`。取回固定点→真实GPG/签名/所有块原件→PG16 actual pg_restore→核心PGP/HMAC实际行→AI clone/current issuer→配置/凭据审查→精确point/config commission→关闭FD→GC。任一步失败保原 proof/最后成功证据，停止宣称 GO，找明确 phase/原始原因修；没有无限重试或复制旧JSON改日期。
7. 读回本次 `/var/lib/uten-imp-dr-verification/{status.json,last-restore-report.json,last-credential-review.json,health.json}` 和云 `.latest-commissioning.json`/`.verification-status.json`。核 session/report/input/config/SW SHA一致、真实 counts、PGDATA/内存观测峰值、实际elapsed、无API可用性冒称、FD退出、稳定1根、quota/minfree不变。当前真实6GiB库未按此跑完就仍是待验，不能用合成大文件代替。
8. 恢复专用 snapshot timer并读到新的真实 complete point与 source capture age≤900秒；停周期重复 full DR timer（不是本地 paired/pgBackRest timer）。只有此后才能称当前 remote freshness恢复。再enable周timer与daily health timer，读回 next/last/result；Persistent不是成功证据。已有旧namespace的retire由Root在新代次实证后按既定CAS处理，不由本执行器删除未知目录。

## 周期、失败与回退

周日北京时间03:00实际恢复，证明最长30天、示例28天，每次都从本次数据重算。超过8天无真实成功，或任一次新失败，health=DEGRADED；expiry余7/3/1天分别可见WARNING/HIGH/CRITICAL，过期原代码拒绝新upload且旧点/证明不伪延长。publisher仍只发原health/最多100点、≤128KiB，不把keysCovered/verified改true。详细原因在受控health JSON/journal；没有外部推送地址时 `externalNotificationDelivered=false`，不声称某人已收到通知。

恢复私有spool/GPG home/容器在正常错误与signal清理；SIGKILL遗留只按instance+PID/start/boot与实际隔离检查回收已证明owned clone，不清理未知路径。脱敏last报告与recipient-encrypted preimage有界保存，dump/config明文不作历史仓保留；unlink不是物理擦除证明。

回退：只disable这两个新timer，等本次job完成或受控取消；保留云完整点/commissioning/本地14d链，不退日期、不删expiry marker。检查owned clone/FD均结束后，按本次SHA归档准确unit/drop-in/forced-key条目；没有其他容器使用新profile后再 `apparmor_parser -R`该准确policy。还原既有 source/receiver配置须保同代次/同recipient/chunk identity；不能把旧key环境与新opaque对象混搭。恢复源 freshness前明确维持DEGRADED/COMMISSIONING_REQUIRED，不把停上传当健康。
