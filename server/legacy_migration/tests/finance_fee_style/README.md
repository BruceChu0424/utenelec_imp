# 历史收款其它费用项目来源回归

本目录的Java和Python脚本使用仓库合成fixture、完整Flyway SQL及Java依赖，在随机命名的独立PostgreSQL容器中复跑V912的23项断言。不读取应用.env、真实业务库或人员资料，结束精确删除自身容器。

```powershell
$pythonExe = 'C:\Users\bruce\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $pythonExe <仓库绝对路径>\server\legacy_migration\tests\finance_fee_style\test_legacy_quantity_counter_protocol.py `
  --repo <仓库绝对路径> `
  --classpath-argfile <包含Flyway、JDBC、Jackson的classpath-argfile> `
  --output-directory <全新私有证据目录> `
  --migration <仓库绝对路径>\server\src\main\resources\db\migration\V912__legacy_receipt_other_fee_style_snapshot.sql
```

覆盖原类别ID保留、收入/缺失节点不充当当前费用、合法历史EXPENSE保持原UUID、0/空与负ID、旧proof仅NULL兼容、新列防伪和不可改、源文件/完整投影/SHA/跨事务校验，以及普通业务类别守卫。原费用、现金、应收金额不变，不创建新分类、审批、GL或现金流水。

本机另以6条真实完整typed源记录复测成功，收据见[迁移说明](../../../../docs/数据迁移/V912-历史收款其它费用项目原始身份.md)。真实载荷不放入测试目录或日志。合成回归及真实样本均不代替整批导入、只读验收和实际账号登录。