# Root 普通财务前置（prep）

已在 Root 隔离库 `127.0.0.1:26630/feedback` 新增 **1 个普通合成财务账号、7 个未映射合成科目**，没有配置任何用途映射、生成 GL、审批退货或再造物料业务单。产品源码未改；最终运行版本尚未冻结，本目录不是 Web 通过证据。

工作树基于 `55d74b716acf49e8b6d81024f062cdebe46e518b`。按 Root 指定只读复制 `evidence/root/b-ui-prep-eba5-build` 至本树私有 `build-root-finance-run1`，8142 个主程序产物复制前后 SHA-256 同为 `f9c1c6448a1a5c67367e76306e79708c4faaf7130f438a40c77ae7d2f27d710b`；只编译本目录测试覆盖层，不触 live runtime classes。执行期间 Flyway 确认为 v1131，无迁移。

## 新普通财务账号

- login：`USR-b-finance-ui-a635aa02`
- userId：`0b887a85-239a-4118-8d3f-246b166a7189`
- employeeId：`73b11ea4-25fd-4fd5-ac0c-132c04514de5`
- `is_super_admin=false`、`must_change_password=false`；与原 maker/approver 分离，未授退货审批权限。
- 密码仅使用 Root 私有 runtime 的 `syntheticAccountPassword`，本目录及提交不含值。
- 权限：`payment_style:view`、`payment_style:edit`、`payment_style:create`、`finance_post:execute`、`finance_report:view`、`finance:view:all`。现有公开创建接口明确要求 `payment_style:create`，不能拿 edit/view 代替；只为本次新账号补必要 create，旧账号/旧授权不改。

身份与密码只用标准 fixture 建立；随后 `harness.loginAs(newActor)` 实证非超管、非强制改密及上述权限，**七个科目全部由该普通财务主体调用原公开 `PaymentStyleService.create` 创建**，对应 `POST /api/master/payment-styles`，未直接 INSERT 科目业务，未跳过原创建守卫。用途配置仅做 `roles.list()` 资格读取，不调用 configure。

## 留给 Root 实际 UI 配置的对应

准确 ID/名称/类别及全部既有 usable 用途见 [finance-seed.json](root-finance-run2/finance-seed.json)。以下名称前缀均为 `B验收合成-`，尾缀均为 `-a635aa02`，中间为完整 roleKey。

| roleKey | 新科目代码 | 类别 | 新科目 ID |
| --- | --- | --- | --- |
| INVENTORY_ASSET | SK000001 | ACCOUNT | 4c1a909f-52d9-4303-aab2-e987f3431592 |
| PROCUREMENT_GRNI_PENDING | SK000002 | LIABILITY | b9a28d09-8432-4aef-adb2-39561e46f519 |
| PROCUREMENT_RETURN_PENDING_ASSET | SK000003 | ACCOUNT | 9d8e8bd1-c11d-403e-8973-be134740d94f |
| PROCUREMENT_RETURN_VARIANCE | SK000004 | EXPENSE | a3be929d-eebf-4bb5-9e76-c0876988d2f3 |
| SALES_COST | SK000005 | EXPENSE | 00dac92d-3aaf-48c3-b1b1-914ba6597de7 |
| SALES_REVENUE | SK000006 | INCOME | 2c31c181-cfa3-4256-ba3d-7873ffa5e009 |
| SUPPLIER_PREPAYMENT_ASSET | SK000007 | ACCOUNT | cdc43873-2228-49fd-b27f-c07f40aac7e4 |

1. Root 用 CUA 登录上述新账号，打开 `/basicinfo/payment-style`（收付款类别）。顶栏图标 tooltip 为 **系统科目用途**。
2. 面板按每行用途说明核对 seed 的 roleKey；尚未配置项的对应类别下拉显示 `代码 · 名称`。选择表中准确 SK 代码，再点 **保存用途**。每项保留真实点击、实际响应、刷新后映射及 SQL 证据。已有 usable 项显示 **已配置：原科目**，保持原样。
3. 正常公开读取 `GET /api/finance/posting-style-roles`，配置 `PUT /api/finance/posting-style-roles/{roleKey}`，body 为 `{styleId, expectedUpdatedAt}`；页面从当次真实读取取版本。接口要求 edit + finance_post:execute，读要求 view + finance_post:execute。若已有无效历史引用，恢复原科目，不替换原用途。
4. 本次 seed 没执行这些配置。`root-before-1.json`、`root-after-run2.json` 和差异 proof 证明当时全部角色映射逐字等同，原 12 科目、原账号所核字段保持；仅新账号和新 7 科目增加，库存/AP/GL/退货/分析 command 计数均未变。

## GL 辅助调用与实际报表页分栏验收

源码全 `lib` 未找到 `/finance/gl/generate` / `generate-all` 调用；当前 `/finance/report/gl` 是 `FinanceReportTablePage(cardId:'gl')`，**没有 GL 生成网页按钮**。不新增产品按钮、不编造 UI 操作。

待最终候选的真实不同岗位退货审批完成、必要科目映射由 Root 在真实 UI 配好且期间合法后，由独立普通财务主体执行原公开 `POST /api/finance/gl/generate?period=2026-11`（`finance_post:execute`）。这是辅助公开 HTTP 证据，不能写成“真实 UI 生成”。本次未执行该请求。

随后 CUA 以该普通财务账号打开 `/finance/report/gl`，核对标题 **总账报表**、默认 **科目余额表** 及 **月度资产负债表** 等变体，日期范围设实际验收期间。科目余额表实际读取 `GET /api/finance/reports/gl/trial-balance?dateFrom=...&dateTo=...`；列表完整性、读取资格、合计及数据库 GL 凭证/分录按同一次实际运行核查。报表 UI 读取、普通财务公开 HTTP 生成、数据库对照分别记录；原 maker 缺 view 的拒绝不由本夹具放宽。

## 原红、验证与重跑

- `root-finance-run1`：1 项 ERROR，原 bootstrap 强制改密，public create 正确 AccessDenied；整段 TransactionTemplate 回滚。原 log/XML 保留；`run1-rollback-proof.json` 证明 roles/styles/accounts/businessCounts 四组全等，没有残留新身份或新科目。没有修改 bootstrap 或绕它的守卫。
- `root-finance-run2`：1/1 通过，编译 0/无警告。普通新账号公开创建，单事务提交；seed 只在成功提交后写出。原账户密码等保护字段在事务内只做摘要相等断言，不输出值。
- `run2-only-new-fixture-proof.json` / 后续 owner 扩展 proof：只读 RR 前后对照，全部检查通过。私有 build、JAR、TMP 均忽略，原始日志以字节保留。
- `snapshot_finance.py` 可对当前孤立库再做新的只读快照；拒绝覆盖旧证据。
- `run_finance_prep.py` 是显式新夹具写入工具；**当前账号/七科目已经存在，不要为验收重复执行或重置**。若今后在明确新种子窗口重跑，使用新的 run 路径和受控合成库配置；只读复制输出，不把 source/live build 当编译目标。

无 main 合并、push、公司库操作、部署或正式打包。Root 后续实际 UI 映射/退货/HTTP GL/报表读取尚未由本目录代签。
