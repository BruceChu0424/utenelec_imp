# 生产历史初始计数协议真实 PostgreSQL 回归

`run_adversarial.py` 可独立重跑 V913 的关键拒绝与合法路径。它复用仓库的本地 Docker 端点检查，仅读取调用者明确提供的结构基线及当前仓库 SQL；不读取 `.env`、真实迁移 CSV、受保护账号快照或既有业务库。

需要 Python 3 和 Docker。每次创建随机命名的 PostgreSQL 16 容器，使用 `--network none`，不开放端口、不挂载现有目录，仅通过 `docker exec` 操作该自有容器。结束或异常时精确删除自有容器。脚本不连接 `uten-imp-postgres`。

调用者必须明确提供 **V913 之前的完整 PostgreSQL 16 schema-only 基线**，包含真实函数、触发器、约束及索引，且没有业务数据。可以使用既有完整迁移测试夹具生成的结构文件；导出时应使用 `pg_dump --schema-only --no-owner --no-acl`。本入口不会自行访问或导出本地应用数据库，也不把结构恢复称为从零执行全部 Flyway 迁移。

```text
python server/legacy_migration/tests/production_counter/run_adversarial.py \
  --schema-baseline <明确提供的完整schema-only基线.sql> \
  --repository-root <当前仓库根目录> \
  --output <新的私有证据目录>
```

默认读取当前仓库的 `V913__legacy_production_plan_counter_provenance.sql`、`migrate_production.sql` 和原始系统参考种子。验证尚未集成的候选 SQL 时，添加 `--migration-sql <候选SQL>`。脚本冻结本次实际读取的文件字节与 SHA，拒绝覆盖已有证据目录；不依赖某个盘符、旧提交或历史私有结构文件路径。

当前 loader 的原业务 INSERT 独立于协议 projection 函数执行。提取器只剥离已知的两个 provenance 前缀列及其临时 proof JOIN；如果 wrapper 变动而不能明确识别，会要求维护者复核，不静默重写业务字段。

覆盖完整 45 列 item / 15 列 parent、合法首次历史超量、负数与 NaN/Infinity、无 proof 或只设 GUC、身份/主档/文件/字段篡改、孤立 proof、先 SUCCESS/PASSED 再 deferred、提前 SET CONSTRAINTS 后修改、来源指针与证据不可变、普通新单、提交后增长拒绝与合法纠减、未来新增业务列，以及授权的合成重置后保留退役 proof 并以新 run/UUID 重导同一旧 ID。合成重置用于验证协议兼容性，不等于执行平台完整重置接口或用户验收。

添加 `--benchmark` 可额外量测 1,000 / 5,000 行正常守卫下的注册、原 INSERT 与 deferred 阶段，在终验前附加大 summary 并记录嵌套真实点查计划。常规回归默认不量测性能。

不启动 Docker 的提取器/CLI 回归：

```text
python -m unittest discover -s server/legacy_migration/tests/production_counter -p test_harness_rendering.py -v
```

退出码 `0` 只表示本次明确结构基线和候选 SQL 的合成回归通过、自有容器已清理；不代表真实整库导入、切换、账号登录或应用验收成功。
