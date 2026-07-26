# 27 - 业务四模块 DDL 一致性契约（V50–V59 落地单一事实源）

> 本档是销售/委外/生产/钱流四模块 Flyway DDL 的**跨模块一致性约束**。各模块具体表设计见 [20][22][24][26]；本档只规定**所有模块必须共同遵守的约定 + 跨模块共享对象**。DDL agent 写每个 .sql 前必读本文 + 自己的 design doc + `V44__purchase_documents.sql`/`V48__stock_documents.sql` 范本。
> 调研见 [18]；老库溯源见 [19][21][23][25]。

---

## 一、Flyway 编号与文件归属（不可越界）

| Flyway | 文件 | 归属 agent | 拥有的表（仅此文件可 CREATE） |
|---|---|---|---|
| **V50** | `V50__finance_master.sql` | 钱流 | `accounts`、`payment_styles`(+闭包/路径表，对齐 V31) + 权限 seed |
| **V51** | `V51__sales_documents.sql` | 销售 | `sales_quotes`(+items)/`sales_orders`(+items+cost_items)/`sales_shipments`(+items)/`sales_other_shipments`(+items)/`sales_returns`(+items) + 权限 seed |
| **V52** | `V52__sales_report.sql` | 销售 | `sales_monthly_mv` 物化视图 + 刷新函数 |
| **V53** | `V53__subcontract_documents.sql` | 委外 | 8 主+8 明细+`subcontract_order_cost_items` + 权限 seed |
| **V54** | `V54__subcontract_report.sql` | 委外 | `subcontract_monthly_mv` |
| **V55** | `V55__production.sql` | 生产 | `production_plans`(+items)/`production_plan_costs`(**按年分区**)/`production_daily_reports`(+items) + 权限 seed |
| **V56** | `V56__production_report.sql` | 生产 | `production_monthly_mv` |
| **V57** | `V57__finance_documents.sql` | 钱流 | `ar_ap_ledger` + `finance_receipts`(+lines)/`finance_payments`(+lines)/`finance_expenses`(+items)/`finance_other_incomes`(+items)/`finance_bank_transfers`(+lines)/`finance_reconciliations` + 权限 seed |
| **V58** | `V58__finance_report.sql` | 钱流 | `finance_ar_ap_mv` |
| **V59** | `V59__stock_partition.sql` | 我亲自写 | `stock_movements` 在线转 RANGE 分区 + movement_type 15–20 注释 |

> **依赖序**：V50→V51→V53→V55→V57（生产 V55 的 SOCItemID/S_OrderID 映射依赖销售 V51 先落，但 DDL 层面无 FK 跨模块，仅迁移时需序）。各模块 DDL 互不 FK（跨模块联动在 Service 层）。

---

## 二、通用建表约定（所有业务表，照 V44）

- 主键 `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`。
- 溯源 `legacy_id INT`（**主表加 UNIQUE；明细不加 UNIQUE**——委外 [22] 吸取仓库踩坑：跨表 IDENTITY 重复；分区明细用 `UNIQUE(legacy_id, bill_date)`）。
- 单据号 `bill_no TEXT NOT NULL` + `UNIQUE(bill_no)`（主表）；明细冗余 `bill_no TEXT NOT NULL` + `bill_date DATE NOT NULL`（查询裁剪 + 报表免 JOIN 主表）。
- 状态 `status SMALLINT NOT NULL DEFAULT 0`（`0草稿/1已审/-1红冲`）+ `is_closed BOOLEAN NOT NULL DEFAULT FALSE`（Service 派生）。
- 金额双口径：`*_original NUMERIC(18,4)`（原币）+ `*_local NUMERIC(18,4)`（本币）；数量 `NUMERIC(18,4)`；汇率 `NUMERIC(18,6)`；税率 `NUMERIC(18,4)`。**严禁 float 存金额/数量**（老库反模式）。
- 多币种：`currency_id UUID REFERENCES currencies(id)` + `exchange_rate NUMERIC(18,6) DEFAULT 1`。
- 审计四件套 `created_at/updated_at TIMESTAMPTZ DEFAULT now()` + `created_by/updated_by UUID` + 软删 `is_deleted BOOLEAN DEFAULT FALSE` + `deleted_at TIMESTAMPTZ`（主表）。**明细/行表也必须带 `created_by/updated_by`**——因明细 Entity 都 `extends BaseEntity→AuditableEntity`（同采购 V44 范式，Hibernate `ddl-auto=validate` 会校验）。> ⚠️ 本档早期版本误写"明细可省 created_by/updated_by"，已订正：V60 补齐 21 张明细表 created_by/updated_by，V61 补 finance_expense_items/other_income_items.remark。建新模块明细表务必带 4 审计列。
- **多值溯源字段**（老库 SOrderNo/InNo/OutNo/BomItemID/POrderNo/EONo 等 varchar 逗号串）→ **前缀化合并为单个 `source_doc_no TEXT`**，格式 `'PO:单号1,单号2 | EI:单号3 | SO:单号4'`（保留类型前缀便于未来回填真 FK）。同一明细若需保留多个，仍合并到一个 source_doc_no。
- 人员字段（maker/approver/seller/sender/receiver/applicant/purchaser/worker `*_id UUID`）：**不建 FK**（employees 与老库 B_Worker 无 legacy_id 对齐，迁移留空，新系统录当前登录用户）。
- 老库 `Status2`（上一次状态）**不迁**（新库状态机显式）；老库 `Cancel bit` → 不单独建列，红冲 `status=-1` 表达。
- 每张表：`COMMENT ON TABLE` + 关键 `COMMENT ON COLUMN`；索引覆盖 `bill_no`/`bill_date`/`status`/`legacy_id`/外键/`goods_id` 等（照 V44 索引清单）。

---

## 三、库存骨架（复用 V45 `stock_movements` + `stock_balances`，movement_type 扩展）

销售/委外/生产审核 → Service 同事务写 `stock_movements` + upsert `stock_balances`。`movement_type` 全表（V45 已建 1–14，本批 15–20 仅注释约定，不改列）：

| type | 含义 | direction | 来源 |
|---|---|---|---|
| 1/2 | 采购入库/采购退货 | +1/-1 | 采购（已用） |
| **3/4** | 销售出库/销售退货 | -1/+1 | 销售（本批） |
| 5/6 | 生产领料/生产退料 | -1/+1 | 仓库（已用） |
| 7/8 | 调拨入/调拨出 | +1/-1 | 仓库（已用） |
| 9/10 | 盘盈入/盘亏出 | +1/-1 | 仓库（已用） |
| 11/12 | 其它入/其它出 | +1/-1 | 仓库（已用） |
| 13/14 | 产成品进仓/产仓 | +1/-1 | 仓库（已用） |
| **15** | 委外材料出仓 | -1 | 委外 E_SOut |
| **16** | 委外材料退回 | +1 | 委外 E_SWithDraw |
| **17** | 委外成品进仓 | **+1**（不照搬老库 E_In 反向！） | 委外 E_In |
| **18** | 委外成品退 | -1 | 委外 E_WithDraw |
| **19** | 委外材料损耗 | -1 | 委外 E_SWaste |
| **20** | 销售其它出库 | -1 | 销售 S_OtherOut |

`source_doc_type` = 模块前缀（如 `'SALES_SHIPMENT'`/`'SUBCONTRACT_RECEIPT'`），`source_doc_id`→单据 id，`source_item_id`→明细 id。

---

## 四、ar_ap_ledger 契约（钱流 V57 独家 CREATE，其余模块仅 Service 调用）

> 销售/委外/生产的 DDL **不**创建也不 FK 到 `ar_ap_ledger`；它们在 Service 审核时调钱流 Service 写入。契约字段（V57 必须照此建，其余模块 Service 按此调用）：

```sql
CREATE TABLE ar_ap_ledger (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    direction         TEXT NOT NULL,            -- 'AR' 应收 / 'AP' 应付
    source_doc_type   TEXT NOT NULL,            -- SALES_SHIPMENT/SALES_RETURN/PURCHASE_RECEIPT/PURCHASE_RETURN/SUBCONTRACT_RECEIPT/SUBCONTRACT_RETURN/DIRECT_RECEIPT/DIRECT_PAYMENT
    source_doc_id     UUID,                     -- 来源单据 id（跨模块，不建 FK）
    source_doc_no     TEXT,
    bill_date         DATE NOT NULL,
    client_id         UUID REFERENCES clients(id),     -- AR 落此
    supplier_id       UUID REFERENCES suppliers(id),   -- AP 落此
    currency_id       UUID REFERENCES currencies(id),
    exchange_rate     NUMERIC(18,6) DEFAULT 1,
    amount_original_local NUMERIC(18,4) NOT NULL,  -- 原始金额（本币，退货为负）
    amount_settled    NUMERIC(18,4) NOT NULL DEFAULT 0, -- 已核销金额
    amount_balance    NUMERIC(18,4) NOT NULL,     -- = original - settled（Service 维护；预付款可负）
    is_settled        BOOLEAN NOT NULL DEFAULT FALSE,
    settled_date      DATE,
    -- 老库 M_in/M_out 双表合并溯源（解 ID 冲突）：
    legacy_source     TEXT,                      -- 'M_in' / 'M_out'
    legacy_id         INT,
    legacy_bstyle     SMALLINT,                  -- 老库 BStyle（3/18/20 应收侧，1/17/30/21 应付侧）
    remark            TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID, updated_by UUID,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ
);
-- 索引：(direction,bill_date)/(client_id)/(supplier_id)/(source_doc_type,source_doc_id)/(is_settled)/(legacy_source,legacy_id)
```

**跨模块 Service 接口**（钱流实现，销售/采购/委外审核事务内调，`propagation=MANDATORY`）：
- `ArApLedger postArAp(direction, sourceDocType, sourceDocId, partyId, amountOriginal, billDate, ...)` — 立应收/应付
- `ArApLedger reverseArAp(sourceDocId, sourceDocType)` — 退货/红冲反立帐（若有核销 amount_settled<>0 则抛"此单已经存在收/付款，请先反审"）
- `settleReceipt(...)` / `settlePayment(...)` / `reverseReceipt(...)` / `reversePayment(...)`
- `refreshSettlementStatus(ledgerId)` — amount_balance=0 自动 is_settled=true（取代老库 TRI_GatheringCheck）

> ⚠️ 销售 [20] 称此为 `AccountReceivableService.postReceivable`，**统一更名为 `postArAp`**（应收应付同表同接口，direction 区分）。Java 实现时以此为准。

---

## 五、权限 seed 规则（用户钦定：每模块双 category）

每模块**两个 category**：`'XX管理'`（单据 view/edit）+ `'XX报表'`（报表 view）。`sort_order` 分段：

| 模块 | category | sort_order 段 | edit 归属部门 |
|---|---|---|---|
| 销售 | 销售管理 / 销售报表 | 200–279 / 280–299 | DEPT_SALES |
| 委外 | 委外管理 / 委外报表 | 300–379 / 380–399 | DEPT_SALES |
| 生产 | 生产管理 / 生产报表 | 400–449 / 450–469 | DEPT_PROD |
| 钱流 | 钱流管理 / 钱流报表 | 500–579 / 580–599 | DEPT_FIN |
| 基础资料（账户/收付款类别）| 基础资料 | 50–59 | DEPT_FIN（账户）/ DEPT_FIN |

权限点粒度：每张单据 `xxx:view`+`xxx:edit`；每张报表或报表组 `xxx_report:view`。seed 三段（照 V44）：
1. `INSERT INTO permissions(code,name,category,sort_order) ... ON CONFLICT(code) DO NOTHING`
2. view 给所有部门：`INSERT INTO department_permissions SELECT d.id,p.id FROM departments d, permissions p WHERE p.code IN (...:view) AND d.is_deleted=false ON CONFLICT DO NOTHING`
3. edit 给归属部门：`... WHERE d.code='DEPT_XXX' AND p.code IN (...:edit) ON CONFLICT DO NOTHING`

> 超管恒有全权限（既有逻辑，无需 seed）。报表数据内部可见，view 给全员。

---

## 六、分区规则（仅生产 F_PlanCostItem + V59 stock_movements）

- `production_plan_costs`：`PARTITION BY RANGE (bill_date)`（反冗余 bill_date，JOIN BillID→production_plan_items→production_plans.BillDate 取值），初始 2018–2030 逐年 + DEFAULT；PK `(id, bill_date)`；UNIQUE `(legacy_id, bill_date)`；8 索引（含 bill_item_id/parent_id/sales_order_cost_item_id/legacy_id）。
- 其余模块明细（销售~9万、委外~9万）**首版不分区**（单表+索引够用），但 `bill_date` 留位，未来可在线转分区。
- V59：`stock_movements` 在线转 `PARTITION BY RANGE(transaction_date)`（建新分区表+插回+rename，或 pg_partman），低峰执行。

---

## 七、迁移幂等约定（各模块 migrate_*.sql，照采购 migrate_purchase.sql）

1. 开头 `TRUNCATE <本模块表> RESTART IDENTITY CASCADE;` + 清本模块 `stock_movements WHERE source_doc_type LIKE '<MODULE>_%'` + 清本模块 `ar_ap_ledger WHERE source_doc_type LIKE '<MODULE>_%'`（钱流）。
2. staging（真实类型）→ `\copy` → INSERT JOIN 主档 `legacy_id` 映射出 UUID。
3. 缺失基础资料自动补录（goods/colors/units/warehouses/currencies/clients/suppliers + 本批 accounts/payment_styles）。
4. 多值 varchar → 前缀化 `source_doc_no`。
5. 结尾校验段：主/明细数、链路挂接、孤儿数、（生产）分区分布、（钱流）ar_ap_ledger direction 对账 M_in/M_out 总额。

---

## 八、交付前自检（每个 DDL agent 写完必做）

- [ ] 表名/列名全小写下划线，与本文 + design doc 一致。
- [ ] `legacy_id` 主表 UNIQUE、明细不 UNIQUE（分区明细 `(legacy_id,bill_date)`）。
- [ ] 金额 `NUMERIC(18,4)` 非 float；双口径 `*_original/*_local`。
- [ ] 多值溯源合并为 `source_doc_no`。
- [ ] 权限双 category + 三段 seed + 正确部门 code。
- [ ] 不越界 CREATE 别模块的表（见 §一）。
- [ ] 每表 COMMENT + 索引齐全。
- [ ] `psql --syntax-check` 或本地 Flyway `validate` 通过（若可跑）。

---

**最后更新**：2026-07-26 · DDL 阶段单一事实源。各 agent 读本文 + 自己的 design doc 落 Flyway。
