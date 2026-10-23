# 生产历史累计独立验收（协议 17 / V913）

本验收用于整批彩排导入成功后、开放系统写入前，以及本地候选库改名后的连续性复核。它保留旧计划数量、工序累计、仓库累计的独立口径，不把历史累计当成现代超产额度，不生成报工、超产审批或库存凭证。它不替代导入事务中的 V913 来源守卫，也不适合作为业务开始正常写入后的永久不变性检查。

## 顺序和门禁

1. 先校验本次新封包的 `derived_inputs.json` SHA、冻结代码提交和全部来源文件，保留原始字节。下面的来源命令默认只读文件，不运行 Docker、不查询目标库、不读取应用配置或秘密。
2. 需要 PostgreSQL 完整类型解释时，显式使用 `--typed-source-only`。此模式先拒绝远程 Docker context / DOCKER_HOST，创建独占、无网络、无端口映射的临时 PostgreSQL 容器，固定其实际容器 ID，再按原 COPY 列顺序和类型解释来源；结束后删除该容器及卷。它不连接候选库。
3. 只有本次真实导入已 `SUCCESS/PASSED` 且调度者明确允许后，运行通用 `verify_rehearsal_result.py` 的实际目标验收。所有目标查询均使用 `REPEATABLE READ / READ ONLY`，不设置迁移 session flags，不注册来源，不调用只适用于 RUNNING 导入的投影或放行函数。
4. 通用回执必须含 `production_counter_baseline.verified: true`。实际 schema ≥913、期望 schema ≥913 或 mapping ≥17 均触发强制生产验收；省略或降低 `--expected-schema` 不能绕过。新协议不得在实际 schema <913 上通过。已有库存、采购销售累计、收货源单和费用分类门禁继续执行。
5. 本地候选库改名后，再以新库名、原库名及第一次成功回执运行同一验收。前后必须保持 cluster system identifier、database OID、本次 run、来源字节和 proof/target UUID 绑定；当前库名可以改变。V913 context 内的原库名仍须等于本次 run 记录的原始目标库名。

## 复跑命令

以下占位符必须替换为**本次新封包 / 新 run** 的实际值。每次使用新的回执文件名，脚本拒绝覆盖旧证据。失败或取消的旧 attempt 的命令和回执不能作为本次目标验收。

```powershell
$python = 'C:\Users\bruce\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$scripts = '<本次冻结仓库>\server\legacy_migration'
$inputs = '<本次 sealed final-inputs 目录>'
$manifest = '<derived_inputs.json SHA256>'
$commit = '<本次冻结提交>'

# 默认离线，不使用 Docker / 数据库。
& $python "$scripts\verify_production_counter_baseline.py" --inputs $inputs --manifest-sha256 $manifest --frozen-commit $commit --output '<新目录>\production-source-offline.json'

# 显式解释完整来源类型；只使用独占的临时无网络 PostgreSQL。
& $python "$scripts\verify_production_counter_baseline.py" --inputs $inputs --manifest-sha256 $manifest --frozen-commit $commit --typed-source-only --output '<新目录>\production-source-typed.json'

# 必须等待本次实际导入 SUCCESS/PASSED 及调度者授权。
& $python "$scripts\verify_rehearsal_result.py" --inputs $inputs --manifest-sha256 $manifest --frozen-commit $commit --admin-snapshot '<本次受保护管理员快照>' --run-id '<本次 run UUID>' --database '<本次候选库>' --expected-schema 913 --output '<新目录>\before.json'

# 仅在同一物理数据库完成受控改名后执行。
& $python "$scripts\verify_rehearsal_result.py" --inputs $inputs --manifest-sha256 $manifest --frozen-commit $commit --admin-snapshot '<同一管理员快照>' --run-id '<同一 run UUID>' --database uten_imp --expected-schema 913 --renamed-from '<原候选库名>' --pre-rename-proof '<新目录>\before.json' --output '<另一个新目录>\after.json'
```

## 独立核对内容

- 动态读取本批和未来封包，不固定行数、源 ID 或异常名单。按 PostgreSQL typed COPY 计算完整 45 列计划明细、15 列原始计划头的逐行 SHA；计划头派生的制单/审核姓名另对封包中的操作员来源核对。
- 对本次来源 ID、父级关系、原引用 ID、排序行号、全部 13 个累计字段、53 个目标绑定业务字段和 20 个实际映射的计划头字段进行独立聚合。源单 UUID、货品、颜色、原料、单位及上游明细由目标当前 UUID 反查实际 legacy 身份；非 NULL UUID 必须对应真实非 NULL legacy 身份。
- 同时检查来源文件 SHA、来源完整行 SHA、来源父级行 SHA、目标完整初始快照、本次 run/MF/freeze、来源截止时点、context/proof 事务身份及数据库原点。目标与 proof 同时被改并自行重签，仍须与独立来源投影一致才能通过。
- 当前明细与本次 proof 双向完整覆盖；未知来源、多余或缺少目标、误绑父级/主数据/单位/源单、伪造行号、字段变更、新增未纳入契约的业务列均拒绝。以前 run 的未绑定来源 proof 按平台 PRESERVE 规则保留，不误计为本轮多余目标。
- 初始允许超产率须保持既有货品结构策略和 DEFAULT 来源，`capped_qty` 必须为空；不允许用 remembered rate、虚假报工、执行段、库存关联或审批增加现代额度。只对原规则要求的 `qty/fqty/iqty` 检查非负；其他十个有符号历史字段不擅自改号。所有数值须有限。

回执只输出聚合计数、SHA、数据库连续性身份和明确的布尔结论；不输出人员信息、原数量、原金额或整行来源。来源单独验收只说明来源已校验，不能声称实际目标导入成功。

## 回归入口

```powershell
& $python -m unittest discover -s "$scripts" -p 'test_verify*.py'
& $python "$scripts\verify_production_counter_postgres_smoke.py" --output-directory '<全新私有 smoke 目录>'
```

第二条使用独占无网络 PostgreSQL 的可变合成数据，证明实际只读 SQL 和独立来源比较能拒绝目标及 proof 同时篡改、父级及主数据身份错绑、context 重签、伪造额度、未来业务列等反例，并实际验证同 OID 改名连续性。它不是全量 Flyway / 真实来源守卫测试，不代替本次实际候选库的成功后验收。
