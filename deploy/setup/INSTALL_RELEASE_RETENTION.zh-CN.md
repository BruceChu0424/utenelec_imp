# Release Retention 安装、恢复与回滚手册

## 1. 当前边界

本目录只提供可审阅的源码候选，不代表目标服务器已经安装，也不代表 retention timer 可以启用。
目标机身份与首次只读连接必须先按
[目标服务器带外身份与访问 authority 清单](../target-host-oob-authority.zh-CN.md)完成 H01–H12；最终 updater
与签名候选还必须来自
[GitHub 保护/签名 authority 清单](../release/GITHUB_SIGNING_AND_PROTECTION_SETUP.zh-CN.md)定义的受保护 lineage。
两者缺一项都不得 `record-plan`、`apply` 或启用 timer。

安装器只管理以下资产：

- 固定路径 retention runtime launcher、manager 和 root entrypoint；
- retention service、timer、alert service；
- `policy.json.example` 示例；
- retention 专用空目录。

它不会修改 `release_updater.py`、`release_guard.py`、release/candidate 内容、既有恢复证据或数据库，也不会创建 live `policy.json`。

`deploy/updater/retention_launcher.py` 中的 `APPROVED_RELEASE_UPDATER_SHA256` 是唯一待级联 pin。Updater 源码尚未冻结时该值必须保持 `None`；此时 `assess` 明确返回 NO-GO，`record-plan`、安装和运行都拒绝。禁止填入占位摘要或当前临时摘要。

## 2. 信任链

```text
独立审阅的固定 installer launcher
  -> O_NOFOLLOW FD + installer SHA-256
  -> assess / record-plan / apply-resume / rollback
  -> 原子安装固定 runtime launcher
  -> O_NOFOLLOW FD + updater/manager 明确 SHA-256
  -> 内存执行已验证 updater，再注入 manager
  -> manager 在任何 receipt/marker/alert 前重新验证两条 live 路径和摘要
```

Runtime launcher 依赖 updater 自身已经固定的 release-guard leaf pin；安装 assessment 同时证明 source/live updater 与 guard 都匹配这条链。

## 3. 一次性独立 bootstrap

不要直接运行源码 checkout 内的 Python 文件。独立审阅人应冻结 `launch-install-release-retention.py` 中记录的精确 allowlist，保持仓库 `deploy/...` 相对布局，并安装为：

- source bundle root：`/usr/local/share/uten-imp-release-retention-installer-source`，所有目录 `root:root 0500`；
- allowlist 文件：`root:root 0400`，不得有额外文件、软链接或多硬链接；
- launcher：`/usr/local/sbin/uten-imp-release-retention-installer`，`root:root 0500`；
- launcher 内 `REVIEWED_INSTALLER_SHA256` 必须等于冻结 installer 的实际 SHA-256。

旧 `install-release-retention.sh` 只是无写 compatibility shim：它只转交上述固定 launcher；launcher 不存在时以 78/NO-GO 退出。

## 4. 前置条件

执行任何写阶段前必须同时满足：

1. `/var/lib/uten-imp-release/operation.lock` 已存在，`root:uten-imp-updater 0660`、普通单链接文件；
2. `uten-imp-retention.timer` 与 `uten-imp-updater.timer` 事先均为 `disabled` 且 `inactive`；
3. retention/updater service 均为 `inactive`；
4. 固定 updater、guard source/live 字节与批准 pin 一致；
5. 所有现有安装目标都是可确认的 root 单链接普通文件，或明确不存在；
6. live `policy.json` 若存在，必须为 `root:root 0600` 且是无重复键的 canonical 数值策略；若不存在则按“不存在”进入 plan；
7. 两名不同审批人共同批准同一 assessment SHA-256。

安装器不会通过 `disable --now`、`stop` 等命令制造这些前置条件。

## 5. Assess：只读

```bash
sudo /usr/bin/python3 -I -B \
  /usr/local/sbin/uten-imp-release-retention-installer -- assess \
  > /root/retention-assessment.json
```

stderr 输出 `ASSESSMENT_SHA256=...`。Assessment 包含：

- 每个 asset 的 source/target/mode/source SHA-256/size；
- target preimage 的 missing/present、摘要、mode、owner、size；
- updater/guard/manager pin 关系；
- 所有将创建或复用的目录；
- timer/service 现场状态；
- live policy 的原始 SHA-256、canonical SHA-256 和完整数值输入；
- blockers。

该命令不创建目录、plan、receipt 或 lock 文件。

## 6. Record plan：双人审批且先取锁

两名审批人分别复核 assessment 内容和摘要后：

```bash
sudo /usr/bin/python3 -I -B \
  /usr/local/sbin/uten-imp-release-retention-installer -- record-plan \
  --expected-assessment-sha256 '<ASSESSMENT_SHA256>' \
  --approver-one 'ops.alice' \
  --approver-two 'security.bob' \
  --approval-reference 'CHANGE-RETENTION-2026-001'
```

`record-plan` 首先取得共享 `operation.lock`，重新执行完整 assessment；任何漂移或 blocker 都在写 plan 前拒绝。输出固定 plan 路径和 `planSha256`。Plan 不可覆盖。

## 7. Apply 与崩溃恢复

```bash
sudo /usr/bin/python3 -I -B \
  /usr/local/sbin/uten-imp-release-retention-installer -- apply \
  --plan '<固定 planPath>' \
  --expected-plan-sha256 '<PLAN_SHA256>' \
  --confirm 'APPLY-RELEASE-RETENTION:<PLAN_SHA256>'
```

Apply 在共享锁内再次比较完整 assessment，随后：

1. 持久化 transaction 与每个既有 target 的精确 preimage；
2. 创建 plan 中明确缺失的目录；
3. 逐资产使用同目录临时文件、`fsync(file)`、原子 `replace`、`fsync(parent)`；
4. `systemd-analyze verify`、`daemon-reload`；
5. 复验 installed SHA/mode、loaded FragmentPath、live policy 未变；
6. 复验两个 timer 仍为 disabled/inactive，两个 service 仍 inactive；
7. 写入 uncommissioned receipt，再关闭 active transaction。

任一阶段崩溃时，不要删除 `active.json` 或 transaction。计算当前 transaction 文件摘要并恢复：

```bash
TX='<transactionPath>'
TX_SHA="$(sha256sum "$TX/transaction.json" | awk '{print $1}')"
sudo /usr/bin/python3 -I -B \
  /usr/local/sbin/uten-imp-release-retention-installer -- resume \
  --transaction "$TX" \
  --expected-transaction-sha256 "$TX_SHA" \
  --confirm "RESUME-RELEASE-RETENTION:$TX_SHA"
```

Resume 对已经写完的精确目标幂等跳过；目标既不等于 preimage 也不等于批准 payload 时拒绝。

## 8. Evidence-bound rollback

仅限尚未 commissioning 的这次 asset transaction：

```bash
TX='<transactionPath>'
TX_SHA="$(sha256sum "$TX/transaction.json" | awk '{print $1}')"
sudo /usr/bin/python3 -I -B \
  /usr/local/sbin/uten-imp-release-retention-installer -- rollback \
  --transaction "$TX" \
  --expected-transaction-sha256 "$TX_SHA" \
  --confirm "ROLLBACK-RELEASE-RETENTION:$TX_SHA"
```

Rollback 先对所有 target 做全量漂移预检，之后只会：

- 恢复 transaction 内已校验的精确 preimage；
- 删除本 transaction 新装且仍等于批准摘要的文件；
- 对本 transaction 创建的目录执行非递归 `rmdir`，目录非空即保留并 NO-GO；
- daemon-reload 并复验原 systemd 状态；
- 写 rollback receipt。

Rollback 不递归删除，不触碰 `/opt/uten-imp/releases`、release/candidate 内容、recovery/database evidence 或 live policy。

## 9. 安装后验收与 NO-GO

```bash
systemctl is-enabled uten-imp-retention.timer
systemctl is-active uten-imp-retention.timer
systemctl is-enabled uten-imp-updater.timer
systemctl is-active uten-imp-updater.timer
systemctl show uten-imp-retention.service -p FragmentPath --value
systemctl show uten-imp-retention.timer -p FragmentPath --value
```

安装 receipt 的合法终态是 `installed-uncommissioned-timers-disabled`。两个 timer 必须仍输出 `disabled` / `inactive`。

以下证据没有被本安装器创建或批准，因此仍是 NO-GO：

- live `policy.json` 的独立双人发布；
- project quota/findmnt 现场验收；
- alert sink 实际交付及 provider receipt；
- 容量阈值、断电/重启、隔离 quarantine 恢复演练；
- updater 最终摘要 pin 冻结；
- timer commissioning 授权。

在这些证据闭环前，禁止 `systemctl enable` 或 `systemctl start` retention/updater timer。
