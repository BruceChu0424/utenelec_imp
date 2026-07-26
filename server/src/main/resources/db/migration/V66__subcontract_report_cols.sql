-- =====================================================================
-- V66：委外报表所需字段补列（委外管理 / 委外报表）
-- =====================================================================
-- 背景：V53 建表时按"业务零割裂 + 底层重设计"取舍，丢弃了若干老库字段；
--   现补回委外 9 张报表（进仓/退货/材料出/材料退 各明细+汇总 + 出入状况表）
--   所需的列，全部为可空列，不影响现有 CRUD/审核/库存联动。
--
-- ① 结帐方式 settlement_style_legacy：老库 E_In/E_WithDraw 的 PStyle（→ B_PStyle
--   字典 ID）。报表按 SubcontractSettlementStyle 字典渲染成文字（现金/提货/...）。
--   仅进仓/退货有（材料出/退 老库无 PStyle）。
-- ② 人员 *_legacy_id + *_name：
--   - 收货人(receiver←E_In.SenderID)、经办人(operator←E_SOut/E_SWithDraw.WorkID)：
--     来自 B_Worker（真实员工）。*_legacy_id 保留 B_Worker.ID；迁移另建 employees
--     stub（legacy_id=B_Worker.ID）→ 报表 LEFT JOIN employees 出名（Option A）。
--   - 制单员(maker←MakeID)、审核员(approver←ApproverID)：来自 Sys_Operator（登录账号）。
--     *_legacy_id 保留 raw Sys_Operator.ID；*_name 在迁移期冻结 Sys_Operator.fname，
--     报表直接显示文本（不进 employees，避免与 B_Worker 撞号）。
--   - 报表人名统一 COALESCE(em.full_name, o.*_name)：em 走 *_id(UUID，新单据当前用户)。
--   employees.legacy_id 列与唯一索引已在 V65 建立，本迁移不动 employees 结构。
-- ③ 明细列：
--   - girth_qty 围数（←KQTY）：进仓/退货/材料退 明细（材料出明细不要，要胶箱）。
--   - step_legacy_id 工序（←StepID）：进仓/退货 明细。B_Step 未迁 → 报表暂空白。
--   - box_qty 胶箱数量：材料出明细（老库无源 → 留空）。
--   - return_amount 退货金额（←EWTotal）：进仓明细。
--   - *_no 交叉引用单号文本（老库多值 varchar 原样迁入，报表直接显示）：
--     进仓明细 return_no(委外退货单号)/order_no(委外订货单号)；
--     退货明细 receipt_no(委外进仓单号)/order_no；
--     材料出明细 return_no(材料退货单号)/order_no(委外订货单号)；
--     材料退明细 issue_no(材料出仓单号)/order_no。
--
-- 详见 docs/数据迁移/22-委外管理-新库与迁移.md 与计划 bright-hopping-stream.md。
-- =====================================================================

-- ---------------- 委外进仓单主表 ----------------
ALTER TABLE subcontract_receipts
    ADD COLUMN IF NOT EXISTS settlement_style_legacy INT,
    ADD COLUMN IF NOT EXISTS receiver_legacy_id    INT,   -- 收货人 ← E_In.SenderID（B_Worker）
    ADD COLUMN IF NOT EXISTS receiver_name         TEXT,  -- 收货人名（JOIN employees 解析；历史冻结兜底）
    ADD COLUMN IF NOT EXISTS maker_legacy_id       INT,   -- 制单员 ← E_In.MakeID（Sys_Operator）
    ADD COLUMN IF NOT EXISTS maker_name            TEXT,  -- 制单员名（迁移期冻结 Sys_Operator.fname）
    ADD COLUMN IF NOT EXISTS approver_legacy_id    INT,   -- 审核员 ← E_In.ApproverID（Sys_Operator）
    ADD COLUMN IF NOT EXISTS approver_name         TEXT;

-- ---------------- 委外退货单主表（成品退） ----------------
ALTER TABLE subcontract_returns
    ADD COLUMN IF NOT EXISTS settlement_style_legacy INT,
    ADD COLUMN IF NOT EXISTS maker_legacy_id       INT,
    ADD COLUMN IF NOT EXISTS maker_name            TEXT,
    ADD COLUMN IF NOT EXISTS approver_legacy_id    INT,
    ADD COLUMN IF NOT EXISTS approver_name         TEXT;

-- ---------------- 委外材料出仓单主表（无结帐方式） ----------------
ALTER TABLE subcontract_material_issues
    ADD COLUMN IF NOT EXISTS operator_legacy_id   INT,   -- 经办人 ← E_SOut.WorkID（B_Worker）
    ADD COLUMN IF NOT EXISTS operator_name        TEXT,
    ADD COLUMN IF NOT EXISTS maker_legacy_id      INT,
    ADD COLUMN IF NOT EXISTS maker_name           TEXT,
    ADD COLUMN IF NOT EXISTS approver_legacy_id   INT,
    ADD COLUMN IF NOT EXISTS approver_name        TEXT;

-- ---------------- 委外材料退货单主表（无结帐方式） ----------------
ALTER TABLE subcontract_material_returns
    ADD COLUMN IF NOT EXISTS operator_legacy_id   INT,   -- 经办人 ← E_SWithDraw.WorkID（B_Worker）
    ADD COLUMN IF NOT EXISTS operator_name        TEXT,
    ADD COLUMN IF NOT EXISTS maker_legacy_id      INT,
    ADD COLUMN IF NOT EXISTS maker_name           TEXT,
    ADD COLUMN IF NOT EXISTS approver_legacy_id   INT,
    ADD COLUMN IF NOT EXISTS approver_name        TEXT;

-- ---------------- 委外进仓明细 ----------------
ALTER TABLE subcontract_receipt_items
    ADD COLUMN IF NOT EXISTS girth_qty      NUMERIC(18,4),  -- 围数 ← KQTY
    ADD COLUMN IF NOT EXISTS step_legacy_id INT,           -- 工序 ← StepID（B_Step 未迁，暂空白）
    ADD COLUMN IF NOT EXISTS return_amount  NUMERIC(18,4),  -- 退货金额 ← EWTotal
    ADD COLUMN IF NOT EXISTS return_no      TEXT,           -- 委外退货单号 ← EWDrawNo
    ADD COLUMN IF NOT EXISTS order_no       TEXT;           -- 委外订货单号 ← OrderNo

-- ---------------- 委外退货明细 ----------------
ALTER TABLE subcontract_return_items
    ADD COLUMN IF NOT EXISTS girth_qty      NUMERIC(18,4),  -- 围数 ← KQTY
    ADD COLUMN IF NOT EXISTS step_legacy_id INT,           -- 工序 ← StepID
    ADD COLUMN IF NOT EXISTS receipt_no     TEXT,           -- 委外进仓单号 ← InNo
    ADD COLUMN IF NOT EXISTS order_no       TEXT;           -- 委外订货单号 ← OrderNo

-- ---------------- 委外材料出仓明细（无围数；要胶箱） ----------------
ALTER TABLE subcontract_material_issue_items
    ADD COLUMN IF NOT EXISTS box_qty   NUMERIC(18,4),       -- 胶箱数量（老库无源 → 留空）
    ADD COLUMN IF NOT EXISTS return_no TEXT,                -- 材料退货单号 ← WDrawNo
    ADD COLUMN IF NOT EXISTS order_no  TEXT;                -- 委外订货单号 ← EOrderNo

-- ---------------- 委外材料退货明细 ----------------
ALTER TABLE subcontract_material_return_items
    ADD COLUMN IF NOT EXISTS girth_qty NUMERIC(18,4),       -- 围数 ← KQTY
    ADD COLUMN IF NOT EXISTS issue_no  TEXT,                -- 材料出仓单号 ← EOutNo
    ADD COLUMN IF NOT EXISTS order_no  TEXT;                -- 委外订货单号 ← EOrderNo

-- ---------------- 报表过滤辅助索引（facet 表头筛选） ----------------
CREATE INDEX IF NOT EXISTS idx_srcpt_settlement ON subcontract_receipts(settlement_style_legacy);
CREATE INDEX IF NOT EXISTS idx_sret_settlement  ON subcontract_returns(settlement_style_legacy);
CREATE INDEX IF NOT EXISTS idx_srcpt_maker      ON subcontract_receipts(maker_legacy_id);
CREATE INDEX IF NOT EXISTS idx_srcpt_receiver   ON subcontract_receipts(receiver_legacy_id);
CREATE INDEX IF NOT EXISTS idx_smiss_operator   ON subcontract_material_issues(operator_legacy_id);
CREATE INDEX IF NOT EXISTS idx_smret_operator   ON subcontract_material_returns(operator_legacy_id);
