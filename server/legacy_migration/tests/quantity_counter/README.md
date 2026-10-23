# 历史累计数量首导证明回归

`test_legacy_quantity_counter_protocol.py` 与同目录 `CounterProtocolAdversarial.java` 是可独立复跑的真实 PostgreSQL 回归。它们仅读取仓库迁移 SQL、合成 `legacy-bootstrap-fixture/rows.json` 和 Java 运行依赖清单，不读取应用 `.env`、真实导入 CSV 或任何业务库连接。

需要 Python 3、Java 21、Docker，以及包含 Flyway、PostgreSQL JDBC、Jackson 的 Java classpath argfile。输出目录可放私有证据目录；脚本每次创建新目录，保留代码、迁移文件的 SHA256、完整 Flyway 和断言结果。脚本创建自身随机命名的 PostgreSQL 容器，只发布 `127.0.0.1` 随机端口，结束后精确删除该容器，不挂载现有数据库或数据目录。

```powershell
$pythonExe = 'C:\Users\bruce\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $pythonExe <仓库绝对路径>\server\legacy_migration\tests\quantity_counter\test_legacy_quantity_counter_protocol.py `
  --repo <仓库绝对路径> `
  --classpath-argfile <Java依赖classpath-argfile> `
  --output-directory <证据输出目录>
```

验证尚未集成的候选迁移时添加 `--migration <V908候选SQL绝对路径>`。常规断言不跑性能量测；添加 `--benchmark` 可额外执行 1,000 / 5,000 行完整源行注册后批量 INSERT，并记录两个阶段耗时、真实键查找 EXPLAIN 与函数调用统计。所有生产约束和触发器保持启用，量测数据回滚。

同时验证 V909 原始可选订货 ID 快照：采购/委外两类收货明细缺上游时保留原 ID，真实 FK 为空，不创造上游订单；真实上游存在时必须精确匹配 UUID；旧 proof 仅允许新列为空，新列不能在线添加、改绑或清空；原数量、主档守卫与未来退货规则继续生效。

覆盖六条真实计数守卫路径：采购订货已收/已退、销售订货已发/已退、销售发货已退、采购收货已退。其中采购收货独立调用既有 V627 注册与投影 API，另三类独立调用 V908 API。验证首次旧超量原值保留且不产生库存、应收应付、到货异常或财审事实；缺证明、执行上下文、目标 UUID/父 UUID、源文件 SHA、完整投影及现代赠品/超收默认量篡改拒绝；证明不可修改删除、来源指针不可清空改绑、目标不可删除重放；跨事务重放、后续增长拒绝；既有合法纠减和退货冲回容量规则保留；普通运行账号不能发行证明；审计按当前 legacy/NONE、重置分类 PRESERVE。

执行上下文测试包含当前 V626 的 run、数据库名、数据库 system identifier、mapping、commit、manifest、BOOTSTRAP/RUNNING 和独占事务锁。现有协议没有单独的授权 epoch 或 business reset generation 字段，结果不声称验证了这两种额外绑定。

脚本退出码 `0` 表示全部断言通过且自有容器清理成功。结果只证明所测冻结 SQL 与合成场景，不代替真实整库导入、正式切换、实际账号登录或用户验收。
