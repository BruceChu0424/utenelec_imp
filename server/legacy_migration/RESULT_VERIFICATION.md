# 整批导入结果的只读验收

`verify_rehearsal_result.py`在本批封存输入和目标库之间建立最终证据。先验证每个CSV、辅助SQL及拓扑摘要的SHA，再在同一 `REPEATABLE READ READ ONLY` 快照内检查指定run SUCCESS/PASSED、冻结commit、集群、保留管理员身份和密码、员工状态、货品、BOM逐边图、待核材料、附件及23项结构回执。实际密码登录单独记录；程序不输出账号、姓名、密码哈希、密钥或完整users/run行。

预期人数、BOM边数、材料和附件数从本轮封存文件计算，不沿用本次彩排的193/195354/3129/2。新增客户货品名称的来源和目标逐键核对另行执行，不把将来都为空写死。原始库存逐键守恒和业务模块证明在全量导入事务内执行，本工具核验相应成功回执。

所有输出必须写到全新私有文件；任何阻断失败停止切换，不覆盖旧证据。`--offline-only`只表示输入已验证，没有连接目标库，不能作为切换验收。

显式 `--expected-schema 908` 或更新版本要求 run 的 mapping 至少为 `bootstrap-v14`，缺失或旧协议直接失败，不能跳过历史基线检查。旧 schema 907/v13 仍兼容。V908 与 `bootstrap-v14` 起，验收额外在同一只读事实快照核对三类历史累计数基线：采购订货、销售订货和销售出货明细。预期数量与完整旧 ID 集合从封存的三份 CSV 动态推导；同 run 的 proof、固定 target_fields、源文件 SHA、完整目标投影 SHA 及 target 双向覆盖必须全部一致。错 run、空 run、额外 proof、缺目标、缩减字段或原始投影改变均阻断验收。当前三类 loader 没有排除协议；将来若需要正式排除，必须先新增可联核的源模块排除证据，不能只调小预期数。采购收货复用 V627，六类原始历史超收/超退只输出待核计数，不视作财务批准，不提高容量；采购收货原始 CSV 行数不直接作为目标数，仍按既有 DROP 仓排除协议核对。改名后还必须与切换前回执的历史基线证明完全一致。

V909/mapping-v15起，还独立核对采购/委外收货原上游ID：从本轮源、DROP对照和真实上游集合计算整数/父子关系SHA，同一只读快照核验原始ID、完整proof、实际UUID、缺链和没有补假订单。V912起，实际schema自动触发收款费用项目验收，不能用省略或传低版本绕过：原qtfymc整数投影独立核对，当前UUID仅匹配同原ID的真实EXPENSE，完整来源投影保持，旧未决费用保留。该阶段70项回归（原53＋费用17）通过，另有隔离PG22个关系与11个费用聚合场景；这两种关系/费用整数核对不声称重编整个CSV typed JSON行SHA。

mapping-v16起必须额外返回`stock_movement_checks.verified=true`，省略或传低`--expected-schema`不能绕过。预期表头、明细、仓库映射、实物事件及零数量非事件均从当次18份封存输入独立推导；逐项比较原数量/单价/金额/倍率、人员和主档命名空间、仓库及双向事件集合。零数量明细完整保留，盘点仍按非零盈亏量生成事件，不能靠同步修改明细与流水来通过。切换前后还比较同一来源和目标UUID身份。

零事件完整原行SHA另用`verify_stock_typed_source_hashes.py`把8份原CSV字节COPY到自有无网络临时PG，用相同16列typed定义重算；保持NULL、引号空串、换行及numeric语义，不用Python伪造JSONB。仅在实际SUCCESS/mapping16元数据通过后执行；本地Docker context和DOCKER_HOST两者都须为本机端点，远程覆盖在读取或复制源文件前拒绝，结束清理自有容器。离线输入核对不会启动该容器。当前通用聚焦回归96项通过（原70＋库存19＋本地端点7），另有19个隔离PG库存场景、3个typed原字节场景及本批真实来源哈希复核；这些开发证据仍不替代实际候选验收。

V913或mapping-v17起必须额外返回`production_counter_baseline.verified=true`，实际schema和mapping双门禁不能用省略或传低预期版本绕过。独立自有无网络PG按原45列明细、15列表头和同批Sys_Operator冻结名重算typed源SHA及全部业务投影；目标只读快照双向核对源ID、proof、上下文、父子/主档UUID及13个累计量。原生产成本缓存不代替真实材料单耗，也不生成现代报工、领料或库存事实。改名复验须保持同一集群/OID和来源/目标身份；离线输入验证不启动PG、不能作为切换验收。

V914或mapping-v18起还必须返回`finance_master_sources.verified=true`。传入`--finance-seed-baseline`和`--finance-seed-baseline-sha256`，外部基线SHA、封包中的finance_seed_baseline.json及provenance必须一致；实际schema或mapping触发门禁，不能降低expected版本跳过。独立typed源核对资金分类、账户原值、新编号、真实UUID、原账户待核关系、原系统种子及已配置角色；切换前后证明保持一致。人员元数据另用`verify_personnel_source_archive.py`的独立来源期望及同一真实只读快照验证，不能把元数据归档称为业务姓名列已补齐。

V916或mapping-v19起，第7类门禁必须返回`finance_flow_monthly.verified=true`。实际schema≥916要求mapping≥19；mapping≥19也要求实际schema≥916和完整封存来源。省略或传低`--expected-schema`均不能绕过，较旧914/v18回执继续按原协议解释。版本由本轮实际Flyway最高版本和完整SQL清单分别验证，不能用迁移条数推断版本或伪造缺号历史。

`verify_finance_flow_monthly.py`在自有本机、固定Docker context、无网络临时PG中解释完整13列资金流水、typed账户/币种和四类原单据ID/单号。原CSV字节、NULL/引号空串、numeric与时区语义保持，不用Python伪造JSONB行SHA。来源文件SHA、有效/归档ID分区、完整typed源行SHA、每条原始signed金额/日期/账户/币种/单据关系、V626完整19字段proof及目标UUID必须相符；原账户余额、审批或GL不得为了通过验收而改变。真实缺账户/不支持来源的既有archive-only规则保持，归档数量由本批来源推导，不固定为27。

月汇总另外按真实账户、币种和上海月份独立核SUM/COUNT；目标缓存与实际不可变ledger的首尾posting序号和完整月份集合双向精确一致。它不调用rebuild或数据库自身integrity函数来代替来源验收。同步改ledger、重签proof和重建cache也必须因独立源投影不符而失败；篡改月份、计数、原rowSHA、文件SHA、origin或新增未审业务列同样拒绝。首导txid/cluster/OID与全部proof执行身份另核，前后改名需保持完整第7类安全投影连续。

该工具只在指定run实际SUCCESS/PASSED后查询目标；查询处于同一`REPEATABLE READ READ ONLY`快照，固定上海时区和ISO日期输出。离线输入核对不会启动Docker或连接目标。开发侧合成PG正/反例只证明验收查询本身，完整首导及延期守卫另按V916协议回归；两者都不能替代某次真实run的成功回执。

资金来源留档另外按[独立资金来源验收](FINANCE_ARCHIVE_ONLY.md)执行，它在独立无网络PG解释完整typed CSV，再只读核对目标保存的完整原行、SHA、理由及active/archive覆盖；同一run/完整manifest/冻结commit/实际集群和OID都必须一致。通用验收与此独立gate均通过才可切换。
```powershell
# 前置：按主SOP设置 $pythonExe/$importRepo/$targetDb/$runDir。
$inputs = '<本轮prepare成功的final-inputs绝对目录>'
$attempt = '<本轮apply的log父目录>'
$adminSnapshot = "$runDir/admin.private.json"
$runId = (Get-Content -LiteralPath "$attempt/run_id.txt" -Raw).Trim()
$manifest = Get-Content -LiteralPath "$inputs/derived_inputs.json" -Raw | ConvertFrom-Json
$manifestSha = (Get-FileHash -Algorithm SHA256 -LiteralPath "$inputs/derived_inputs.json").Hash.ToLowerInvariant()
$importCommit = $manifest.provenance.importerRepositoryCommit
$expectedSchema = '<冻结迁移目录本轮最高版本号>'
$beforeProof = "$runDir/acceptance-before-rename.json"
$afterProof = "$runDir/acceptance-after-rename.json"
$verifier = "$importRepo/server/legacy_migration/verify_rehearsal_result.py"
$proofArgs = @('--inputs',$inputs,'--admin-snapshot',$adminSnapshot,
  '--run-id',$runId,'--manifest-sha256',$manifestSha,
  '--frozen-commit',$importCommit,'--expected-schema',$expectedSchema)

# 确切run提交SUCCESS/PASSED后，切换前验收。
& $pythonExe $verifier @proofArgs --database $targetDb --output $beforeProof
if ($LASTEXITCODE -ne 0) { throw 'Candidate verification failed; do not cut over' }

# 仅在主SOP完成已授权的本地改名后，复验同一数据库实例。
& $pythonExe $verifier @proofArgs --database uten_imp --renamed-from $targetDb `
  --pre-rename-proof $beforeProof --output $afterProof
if ($LASTEXITCODE -ne 0) { throw 'Renamed database verification failed' }
```

程序拒绝未声明的库名变化。切换前首回执记录当前集群标识和数据库OID；改名后同时核对run、manifest、commit、全部counts、账户证明、BOM图、集群和同一OID，不能以同集群另一个复制库代替。本轮原claim没有记录OID，不补写或伪造历史claim；连续性以首次成功只读验收为起点。

另执行[员工绑定专项](EMPLOYEE_BINDING_AUDIT.md)与主SOP中的真实应用/密文/附件检查。数据库成功回执、离线服务验证、HTTP健康、真实用户登录及人工业务验收分别记录，不相互替代。

验证器回归：`test_verify_rehearsal_result.py`共29项，通过输入漂移、动态人数、RUNNING拒绝、账户/图/文件失败、改名声明和OID连续性及隐私输出。`verify_rehearsal_result_postgres_smoke.py`只创建自身一次性隔离PostgreSQL容器，验证真实改名与READ ONLY拒绝写入，结束删除自有容器；不访问原库/候选库。这些开发回归通过不表示某次实际导入已验收，最终以对应run的真实收据为准。

V908 聚焦回归另有 `test_verify_rehearsal_counter_baseline.py` 8 项（合计 37 项），包括显式908拒绝v13/缺失mapping。原29项用例保留，旧协议合成fixture使用907/v13；`verify_rehearsal_counter_postgres_smoke.py` 在自有 network-none PostgreSQL 验证实际完整投影 SQL，以及修改数量、目标空/错 run、缺目标、缩减字段、错文件 SHA、错旧 ID、错 proof run、额外 proof 和错路由十类拒绝。测试只变更自身合成 fixture，最后删除自有容器；不连接实际候选库。
