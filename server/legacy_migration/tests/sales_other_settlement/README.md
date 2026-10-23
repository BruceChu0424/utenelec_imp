# 历史其它出货单结算方式首次绑定回归

原销售导入先插入 settlement_method_id=NULL，再以旧 B_PStyle ID 补写 UUID。历史其它出货单的真实只读守卫会拒绝该 UPDATE。修复仅在首次 INSERT 按同一个真实旧 ID 查 UUID，保留原始 payment_style_id，并删除这个后置 UPDATE；守卫 SQL 保持原样。

本入口复用相邻 production_counter/run_adversarial.py 的完整 schema、随机自有 PostgreSQL16、严格本地 Docker 检查和清理流程。容器使用 --network none，没有主机端口或挂载；不会连接应用数据库、读取真实 CSV、账号快照或 .env。

调用者必须明确提供 **V913 之前、没有业务数据的完整 PG16 schema-only 基线**，包含真实函数、触发器、约束和索引。脚本随后应用当前仓库的 V913，不自行导出本机数据库，也不把结构恢复声称为从零执行全部 Flyway。

    python server/legacy_migration/tests/sales_other_settlement/run_regression.py \
      --schema-baseline <明确提供的完整schema-only基线.sql> \
      --repository-root <当前仓库根目录> \
      --output <全新的私有结果目录>

集成前可用 --loader <修正后的migrate_sales.sql>。默认读取当前仓库 SQL 与原 V273 字典种子，没有固定盘符、私有源文件或旧提交依赖。每轮冻结 loader 字节、结构/V913/loader SHA 和安全结果。

15 项真实 PG 用例覆盖原后置 UPDATE 的确定拒绝、初次匹配成功与原金额/数量/缓存/原始人员 ID 守恒、后续解绑与普通新单拒绝、NULL/0/未知旧 ID 的原行为等价、禁用/已删方法仍拒绝、不同真实方法 UUID 与原 ID 冲突仍拒绝。所有合成用例使用真实守卫，没有禁用触发器或制造库存、财务流水。

纯离线提取与 CLI 检查：

    python -m unittest discover -s server/legacy_migration/tests/sales_other_settlement -p test_regression_rendering.py -v

测试通过只表示该明确结构与 loader 的合成回归成立。实际整批导入、应用登录、切换、备份和恢复验证需要各自的真实证据。
