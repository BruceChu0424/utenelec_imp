# 05 - YTDQ 老库结构调研

> 本档记录"老系统"数据库 **YTDQ_2023** 的结构与首轮调研结论。
> 通用调研框架见 [01-老系统现状调研.md](01-老系统现状调研.md)；字段级映射见 [04-新老数据映射表.md](04-新老数据映射表.md)。
>
> **调研时间**：2026-07-24 · **调研人**：bruce · **数据时点**：备份制作于 2026-07-22 · **状态**：首轮概览（字段级待逐模块深入）

---

## 一、老库是什么

| 项 | 值 |
|---|---|
| 备份文件 | `D:\Projects\uten_imp\YTDQ_2023-202607`（2.6 GB，**无扩展名**） |
| 形态 | Microsoft SQL Server **完整备份**（`.bak`，TAPE 流格式，`file` 识别为 SQL Server） |
| 数据库名 | `YTDQ_2023` |
| 逻辑文件 | `KYRJ_Data`（数据 1.42 GB）/ `KYRJ_Log`（日志 8.5 MB） |
| 系统性质 | **国产中小型制造业 ERP**（进销存 + 生产计划/成本 + 财务收付款 + 工资 + 质检），内部代号疑似"科宇"（KYRJ） |
| 数据跨度 | 2023 ~ 2026-07 |

> ⚠️ 备份文件（2.6 GB）位于项目根目录，**勿提交 git**——需加入 `.gitignore`。

---

## 二、技术栈（事实）

| 项 | 值 | 说明 |
|---|---|---|
| RDBMS | Microsoft SQL Server | — |
| **源版本** | **2008 R2** | SoftwareVersion `10.50.1600` / DatabaseVersion `661` |
| 兼容级别 | 备份内 `80`（SQL 2000）→ 还原后自动升 `100` | 老库可能从 SQL 2000 一路升级而来 |
| 排序规则 | `Chinese_PRC_CI_AS` | 简体中文，不区分大小写，区分重音 |
| 恢复模型 | `SIMPLE` | — |
| 源机器 | `WIN-OB8EECLBOUI\Administrator` | 老系统部署机 |
| 备份大小 | 1.30 GB（数据文件 1.42 GB） | — |

### 还原方式（已落地）

还原到本机 **LocalDB 2022**（`v17.0.4025.3` / Express Edition），实例 `(localdb)\MSSQLLocalDB`：

```sql
RESTORE DATABASE [YTDQ_2023]
FROM DISK = N'D:\Projects\uten_imp\YTDQ_2023-202607'
WITH MOVE N'KYRJ_Data' TO N'<InstanceDefaultDataPath>YTDQ_2023.mdf',
     MOVE N'KYRJ_Log'  TO N'<InstanceDefaultDataPath>YTDQ_2023.ldf',
     REPLACE, STATS = 10;
```

- 2008 R2 → 2022 跨大版本还原成功，库结构版本从 661 逐级升级到 998，无报错。
- 兼容级别自动 80 → 100，数据/schema 可正常读取。
- 连接串（后续双写/迁移用）：`Server=(localdb)\MSSQLLocalDB;Database=YTDQ_2023;Trusted_Connection=True;`

> 后续如需在团队/服务器还原：目标需 SQL Server 2016+（向下兼容 2008 R2）；Express/LocalDB 的 10 GB 库上限对本库（1.4 GB）无压力。

---

## 三、对象总览

| 类型 | 数量 |
|---|---|
| 用户表 | **196** |
| 视图 | **168** |
| 存储过程 | 11 |
| 函数 | 1 |
| **触发器** | **91** ⚠️ |
| Schema | 仅 `dbo` |

> 触发器极多 —— 业务逻辑大量下沉到触发器（明细写入 → 自动重算主表合计/库存）。**这是影子双写的核心风险**，详见 §六。

---

## 四、模块前缀解码（表名约定）

ERP 按业务域用前缀划分模块，几乎每张业务表都有配套视图（`View_<同名>`）：

| 前缀 | 模块 | 代表表 | 备注 |
|---|---|---|---|
| `B_` | Basic 基础数据 | `B_Goods` 物料、`B_Client` 客户、`B_Provider` 供应商、`B_Worker` 员工、`B_WorkShop` 车间、`B_NPlace` 工位、`B_Unit` 单位、`B_Color` 颜色、`B_Mould` 模具、`B_Bom*` 物料清单、`B_Step*` 工序 | 主数据 |
| `S_` | Sales 销售 | `S_Order` 订单、`S_Out` 出库、`S_Quote` 报价、`S_Withdraw` 退货、`S_Box` 装箱 | 主账套 |
| `P_` | Purchase 采购 | `P_Order` 订单、`P_In` 入库、`P_Application` 请购、`P_Ask` 询价、`P_Withdraw` 退货 | — |
| `O_` | Other 其它出入库 | `O_In/O_Out`、`O_OtherIn/O_OtherOut`、`O_Transfer` 调拨、`O_Check` 盘点、`O_PDraw` 领料、`O_WDraw` 退料、`O_Combination` 组装、`O_Dismantle` 拆卸、`O_Waste` 报废 | — |
| `E_` | （疑似）第二套销售/出口账套 | `E_Order/E_SOut/E_WithDraw/E_Application/E_Ask/E_SWaste` | **与 S_ 结构完全对称**，待确认 |
| `M_` | Money 财务 | `M_Paid` 付款、`M_Get` 收款、`M_DPaid`、`M_OGet`、`M_Acc` 账户、`M_Bank` 银行、`M_Check` 对账 | — |
| `F_` | 生产计划/成本 | `F_Plan` 计划、`F_PlanCostItem` 计划成本、`F_Arrange` 排产、`F_Cost` 成本、`F_Product*`、`F_Step*`/`F_PStep*` 工序、`F_Transfer` | 含最大表 |
| `C_` | Check 质检 | `C_Check`、`C_GoodsCheck` 盘点、`C_InCheck` 入检、`C_StepCheck` 工序检、`C_UnPass` 不良 | — |
| `W_` | Wage 工资 | `W_Project` 项目、`W_Laborage` 工资、`W_PATWork` 计件工、`W_Formula` 公式 | — |
| `Stock` | 库存主表 | `StockGoods` 库存（45 万行）、`StockLabel`/`StockSLabel` 标签 | — |
| `Sys_` | 系统权限 | `Sys_Operator` 操作员、`Sys_Purview` 权限、`Sys_OperatorPurview`、`Sys_Group`、`Sys_Logs` 日志（108 万行）、`Sys_BasicView` | — |
| `T_` | （疑似）第三套账套 | `T_Order/T_In/T_Out/T_Quote/T_SIn/...` | **与 S_/E_ 对称，全部 0 行，未启用** |
| `A_` | Assets 资产 | `A_Dep` 折旧、`A_Assets`、`A_In`、`A_Sell` | 全 0 行，未启用 |

> 🔎 **关键观察**：`S_` / `E_` / `T_` 三套表结构对称（订单/出入库/退货/报价各一套），疑似**多账套/多业务线**设计（如内销/出口/样品）。**需向用户确认 E_/T_ 的含义**——这直接决定双写范围。

---

## 五、核心大表（Top 20，按行数）

| 表 | 行数 | 含义（初判） |
|---|---:|---|
| `F_PlanCostItem` | 1,359,875 | 生产计划成本明细 |
| `Sys_Logs` | 1,078,282 | 操作日志 |
| `StockGoods` | 454,104 | 库存台账 |
| `O_PDrawItem` | 372,345 | 领料明细 |
| `B_BomItem` | 218,822 | BOM 明细 |
| `Sys_BasicView` | 165,529 | 基础视图/权限快照 |
| `O_InItem` | 95,478 | 其它入库明细 |
| `S_OutItem` | 90,948 | 销售出库明细 |
| `S_OrderItem` | 82,601 | 销售订单明细 |
| `F_PlanItem` | 73,388 | 生产计划明细 |
| `O_CheckItem` | 63,575 | 盘点明细 |
| `O_OtherOutItem` | 62,474 | 其它出库明细 |
| `E_SOutItem` | 49,889 | E 账套销售出库明细 |
| `M_Out` | 44,534 | 财务付款单（?） |
| `M_In` | 42,489 | 财务收款单（?） |
| `E_InItem` | 39,093 | E 账套入库明细 |
| `B_Goods` | 35,773 | 物料主档 |
| `O_PDraw` | 35,135 | 领料单主表 |
| `P_InItem` | 34,854 | 采购入库明细 |
| `M_AllCheck` | 30,626 | 财务对账核销 |

> 单据类普遍"主表 + 明细表"成对设计（如 `S_Order` / `S_OrderItem`）。明细表是大头。

---

## 六、触发器风险（双写地雷）⚠️

- **91 个触发器分布在 ~72 张表**，几乎所有业务单据（主表 + 明细）都挂触发器。
- 推断职责：明细 `INSERT/UPDATE/DELETE` → 触发器调用 `RefreshTotal_PROC` / `RefreshPTotal_PROC` → **重算主表合计金额、更新 `StockGoods` 库存**。
- 对"影子双写"的含义：往老库明细表"写一行" ≠ 仅写一行，会**触发连锁更新**（改主表、动库存）。若老系统同时操作同一单据，可能数据错乱。
- 触发器最多的表：`E_OrderItem`/`F_PlanItem`/`T_OrderItem`（各 3 个），多数单据主/明细表各 1~2 个。
- **对策（待定，详见 [02-双写与同步方案.md](02-双写与同步方案.md)）**：
  1. 双写只写"叶子表"，接受触发器连锁（最省事，但连锁不可控）；
  2. 双写时临时 `DISABLE TRIGGER`（违反"不改老库"铁律，需特批）；
  3. 双写整张单据（主表 + 明细）于同一事务，与触发器预期一致。

> 必须在双写开发前，对每张目标表**逐一审阅触发器源码**（`sp_helptext`），确认其副作用范围。

---

## 七、存储过程（11）

| 名称 | 推断职责 |
|---|---|
| `RefreshTotal_PROC` / `RefreshPTotal_PROC` | 重算单据合计（被触发器调用） |
| `SumTPPay` | 汇总应付（?） |
| `Sys_Purview_PROC` / `Sys_PurviewGroup_PROC` / `Sys_PurviewGroup2_PROC` / `Sys_PurviewOperator_PROC` | 权限/权限组维护 |
| `Level_SystemItem_PROC` / `SystemItem_PROC` | 层级/系统项维护 |
| `B_UnitItem_PROC` / `M_Style_PROC` | 单位/样式基础数据处理 |

---

## 八、视图（168）

几乎每张业务表都有同名 `View_<表>` 视图，通常 `JOIN` 明细 + 基础数据，带出物料名/客户名/计算字段——是**老系统报表与查询口径的来源**。迁移时若要复刻某张老报表，先读对应视图的 SQL 即可拿到口径。代表：`View_F_DateReport*`（日报）、`View_StockGoods`/`View_IOStockGoods`（库存/出入库）、`VIEW_W_Laborage`（工资）。

---

## 九、与新系统 Uten IMP 的模块对应（初判）

> ⚠️ 以下为基于表名的**初判**，字段级对应待逐模块抽样确认。新系统状态参考 README 阶段表。

| 老库（表/模块） | 新系统对应 | 新系统状态 |
|---|---|---|
| `B_Worker` 员工 | Employee 员工档案 | ✅ 已实现（Phase 2） |
| `B_WorkShop`/`B_NPlace` 车间/工位 | Department / Position | ✅ 已实现 |
| `B_Client` 客户 | 客户资料（三级数据范围） | ⏳ 待开始 |
| `B_Provider` 供应商 | 供应商资料 | 🔲 占位 |
| `B_Goods` 物料 / `StockGoods` 库存 | 库存查询（PMC） | 🔲 占位/Mock |
| `S_`/`P_`/`O_` 单据 | 出入库记录（PMC） | 🔲 占位 |
| `W_Laborage` 工资 | 工资条 | ✅ 已实现（Mock，待接真后端） |
| `C_*` 质检 | 检测记录（实验室） | 🔲 占位 |
| `F_*` 生产计划/成本 | 流水线看板 / 产量 | 🔲 Mock |
| `Sys_Operator`/`Sys_Purview` | 账号 / 权限管理 | ✅ 已实现（权限模型已重构，与老系统差异大） |
| `M_*` 财务收付款 | 财务报表 / 账户资料 | 🔲 占位 |
| `B_Bom*` 物料清单 | — | ❌ 新系统未规划 |
| `F_Arrange` 排产 / `F_*Cost` 成本核算 | — | ❌ 新系统未规划 |

**关键判断**：老系统是**完整 ERP**（进销存 + 生产 + 财务），新系统目前是**管理后台 + 部分业务点**。融合**不是整体搬迁**，而是新系统已有/将有的业务模块，按需与对应老表双写；老系统有而新系统不做的（BOM、MRP 排产、成本核算等）**不双写**，待新系统自然替代或长期保留老系统。

---

## 十、历史遗留 / 疑似垃圾表（迁移排除）

`temp_20250103`、`SystemItem_bak20230607`、`ys2017`、`hhhhhh$`、`v5`、`ys`、`dbom`、`118bom`、`ProductMore`、`SetColumnsWidth`、`PrintFile`、`RecStyle`、`SystemPart`、`SystemSource`、`SystemAccinfo`、`dtproperties`

> 这些是临时表/备份/配置/打印模板，非核心业务数据，数据迁移与双写均应排除。

---

## 十一、待调研问题（等用户输入）

1. **业务确认**：`E_` / `T_` 两套对称表是否多账套（内销/出口/样品）？哪些是启用中的？
2. **双写优先级**：首批要打通哪个模块？（员工/客户/供应商/库存/工资…）
3. **老系统认证**：`Sys_Operator` 的登录/密码机制？双写是否需要复用老会话？
4. **运行部署**：老系统现网部署在哪？新系统后端能否直连老库（网络可达性）？
5. **退役节奏**：哪些模块老用户还在用、哪些可优先停？
6. **字段口径**：每个双写模块的字段级映射（填入 [04-新老数据映射表.md](04-新老数据映射表.md)）。

---

**最后更新**：2026-07-24 · **当前状态**：首轮概览完成，老库已还原至 LocalDB 可查；字段级调研待按模块逐个推进。
