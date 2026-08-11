-- V221: 委外物料守恒——冻结 BOM 版本 + 逐需求发料子账 + 回厂按 BOM 消费 + 守恒恒等。
--
-- 背景（SOP 01 §七-276 / doc 22 §十-13 / 审计 §五 🔴）：委外发料是公司物料转到供应商处保管，
-- 不是销售出库或立即消耗。此前新发料审核 fail-closed（409）——因为缺冻结 BOM 版本和子件发料
-- 权威台账，无法证明应发版本、回厂耗用与供应商期末结存的守恒。本迁移落地该台账并放开门禁。
--
-- 守恒恒等（全部以"子件单据单位"计）：
--   at_supplier_qty = consumed_qty（回厂按冻结 BOM 消费）+ returned_qty（材料退）+ wasted_qty（损耗）+ supplier_ending
--   supplier_ending = at_supplier_qty - consumed_qty - returned_qty - wasted_qty  （GENERATED STORED）
--   CHECK supplier_ending >= 0  ← 任何途径的超消费（超耗/错料）都被数据库拒绝。
--
-- frozen_unit_qty：审核时从当前 goods_bom_items 冻结的"每单位父件耗用该子件量"，作为本次发料的
-- BOM 版本快照（后续 BOM 变更不影响在途守恒）。回厂时按 回厂父件量 × frozen_unit_qty 消费。
--
-- 自包含前向：建列 + 回填历史 + 生成列 + 约束一步到位。历史发料明细 at_supplier_qty 回填为 qty
-- （既有 V132 CAS 已保证 returned+wasted ≤ qty），故 supplier_ending ≥ 0，历史行不被新约束误伤。

ALTER TABLE subcontract_material_issue_items
    ADD COLUMN IF NOT EXISTS at_supplier_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS consumed_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS frozen_unit_qty NUMERIC(18,6);

-- 历史回填：既有发料明细视为"已发至供应商"（at_supplier = qty），使生成列与守恒约束对历史成立。
UPDATE subcontract_material_issue_items
SET at_supplier_qty = COALESCE(qty, 0)
WHERE at_supplier_qty = 0 AND COALESCE(qty, 0) > 0;

-- 供应商期末结存（生成列）：任何 at_supplier/consumed/returned/wasted 的变更都自动重算，
-- 从而 material_return / waste / receipt 三条途径共用同一守恒口径，无需各自手工同步。
ALTER TABLE subcontract_material_issue_items
    DROP COLUMN IF EXISTS supplier_ending;
ALTER TABLE subcontract_material_issue_items
    ADD COLUMN supplier_ending NUMERIC(18,4)
    GENERATED ALWAYS AS (
        at_supplier_qty
        - consumed_qty
        - COALESCE(returned_qty, 0)
        - COALESCE(wasted_qty, 0)
    ) STORED;

-- 守恒铁律：供应商处结存不得为负（超消费 = 超耗/错料/丢失，必须人工核销而非系统兜底）。
ALTER TABLE subcontract_material_issue_items
    DROP CONSTRAINT IF EXISTS subcontract_material_issue_items_supplier_ending_chk;
ALTER TABLE subcontract_material_issue_items
    ADD CONSTRAINT subcontract_material_issue_items_supplier_ending_chk
    CHECK (supplier_ending >= 0);

CREATE INDEX IF NOT EXISTS idx_subcontract_material_issue_items_order
    ON subcontract_material_issue_items(order_item_id)
    WHERE COALESCE(at_supplier_qty, 0) > 0;

COMMENT ON COLUMN subcontract_material_issue_items.at_supplier_qty IS
    '已发至供应商处的子件量（审核置为发料量；单据单位）；供应商处我方物料台账起点';
COMMENT ON COLUMN subcontract_material_issue_items.consumed_qty IS
    '回厂进仓按冻结 BOM 消费的子件量（单据单位）；由委外进仓审核按 回厂父件量×frozen_unit_qty 累加';
COMMENT ON COLUMN subcontract_material_issue_items.frozen_unit_qty IS
    '审核时冻结的 BOM 版本：每单位父件耗用本子件量（取自当时 goods_bom_items）；回厂消费按此快照计算';
COMMENT ON COLUMN subcontract_material_issue_items.supplier_ending IS
    '供应商期末结存（生成列 = at_supplier_qty - consumed_qty - returned_qty - wasted_qty）；CHECK >= 0 守恒';
