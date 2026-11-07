# 2026-11-06 Legacy bootstrap 清册与 FAILED 事务来源收口

## 136表原根因

当前完整迁移新增136张已知表，而bootstrap目标清册仍只有560张原声明，真实fresh inventory与降级v15负例先被unknown inventory拒绝，无法到原V913生产来源保护。按实际DDL/FK/调用来源逐表审查后，清册只追加20个控制/配置SEED_OR_ADMIN和116个业务/身份/原输入/混合操作EMPTY，560条原声明及unknown/missing/非空/管理员/来源检查不改。逐表证据为docs/数据迁移/evidence/2026-11-06-bootstrap-inventory-classification.tsv；禁止复活V919退休清库或用历史CLEAR分类替代。

## 真实新增摘要与允许证据

固定清册的原完整3案已越过136表阻塞；唯一剩余失败是summary_read_markers11→153，其余每个既有payload指纹全部相同。V1102明确让legacy_migration_runs/run_files成为native-facet-finance-columns依赖。原协议允许FAILED claim、每个文件收据、结束状态和唯一汇总独立提交，这些真实控制证据自然产生事务摘要，不是业务回滚泄漏。

原after-FAILED汇总审计没有首次claim xid，且run.xmin已被结束状态更新覆盖；legacy_account_flow_import_txid只代表后续财务阶段，也不能冒充首次claim。因此claim reconciliation_summary仅增加服务器生成的txid_current()::text，不采信输入，不增DDL/业务写入口。文本保Web JSON超过2^53的身份精度；真实PG验证string与9007199254740993原样往返。

原数据指纹守卫仅精确投影已验证的该FAILED run及其file/audit实际事务在唯一finance域的markers；旧markers、非该run事务、其它域与全部业务payload继续原hash相等，不整表/整域忽略。每个claim/file/status的marker必须实际存在；审计仍仅允许原完整精确FAILED汇总和32表真实回滚计数。xmin低32只在持久完整claim到current区间内唯一恢复epoch，跨wrap/nonzero epoch有实证，存在两种可能或旧行则明确拒绝，不猜epoch0。

## 验证输入与回执

证据根为本树build/backend-e157-ci-20261106：

- 原guard9046的完整3案1pass2fail保留；正确guard1d60第一次完整3案2pass1fail，独立payload差分JSON仅summary表11→153，没有覆盖原失败。
- numeric claim语义轮legacy-1106-marker-origin-v3：完整3/3 native0，707 Python通过、21原合法skip，140.869秒。它不是最终文本字节。
- 最终文本claim/严格string断言/guard1d60/epoch helper：legacy-1107-final-v4，编译Xlint:all/Werror/proc:none0，真实PG3+epoch2=**5/5、无skip/abort、native0**；707 Python通过、21原合法skip，589.755秒。输入1046 SQL/head1107已在启动时冻结，当前资源的1107是当时invoker方案；之后1107函数EXEC防护属于独立安全增量，未改此闭包的claim/回滚语义或本轮运行字节，不冒称全Main完整CI。
- 独立epoch unit2/2：非零epoch与单次跨wrap均保持完整身份，旧行/两个可行epoch不准默认选一个。PG文本身份窄合同0。

此提交只包括清册/审查证据、服务器生成claim审计来源及其测试。未改Flyway已应用SQL、业务数量/精度/权限/源、原V913拒绝、v18 alias提前拒绝、管理员保护或时限。不触公司/用户5434、8080、账号、正式包，不以这些局部回执称全CI或正式迁移验收。