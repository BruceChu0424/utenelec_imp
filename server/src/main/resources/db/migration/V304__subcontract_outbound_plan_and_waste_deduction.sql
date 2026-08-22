-- V304: 委外全链路重设计——发料计划快照 + 自动出仓草稿 + 损耗扣款 + 仓库权限。
--
-- 背景（docs/07-业务链路/08-委外全链路-订货出仓回仓重设计.md）：委外是「先出（材料）
-- 后进（成品）」。财务批准委外订货后，此前没有自动化的材料出仓依据：发料单靠委外模块
-- 手工新建、手工从订货引入，仓库没有自己的出仓任务与页面，订货单也看不到出/进仓进度。
-- 本迁移落地：
--   ① subcontract_material_plans / subcontract_material_plan_items —— 财务批准同事务按
--      当时 BOM 展开的「发料计划」快照，是仓库出仓的权威依据与订货单进度口径；
--   ② subcontract_material_issue_items.plan_item_id —— 出仓单明细挂计划行，审核/红冲回写
--      issued_qty；历史手工单为 NULL，不参与计划进度；
--   ③ subcontract_wastes.deduct_amount / deduct_posted —— 损耗结案时可填写向委外商的
--      扣款金额（本币），审核立负应付；默认 0 = 公司自行承担；
--   ④ SUB_WH（PMC 运营仓储部）补委外出/入仓执行权限（谁执行谁有权，V296 同先例）。
--
-- 计划行数量口径：planned_qty = 订货明细量（父件单据单位）× bom_unit_qty（子件/父件，
-- 冻结自批准时 goods_bom_items.qty），与 V221 守恒消费（回厂父件量 × frozen_unit_qty）同口径。

CREATE TABLE subcontract_material_plans (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id                    UUID NOT NULL REFERENCES subcontract_orders(id) ON DELETE RESTRICT,
    order_bill_no               TEXT NOT NULL,              -- 订货单号快照（人读溯源）
    supplier_id                 UUID REFERENCES suppliers(id) ON DELETE RESTRICT,
    status                      TEXT NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'CLOSED', 'CANCELED')),
    close_reason                TEXT,                       -- 「不再出仓」手工关闭原因
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                  UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by                  UUID REFERENCES users(id) ON DELETE SET NULL,
    is_deleted                  BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at                  TIMESTAMPTZ,
    UNIQUE (order_id)                                       -- 一张订货单一份发料计划
);

CREATE TABLE subcontract_material_plan_items (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_id                     UUID NOT NULL REFERENCES subcontract_material_plans(id) ON DELETE CASCADE,
    order_item_id               UUID NOT NULL REFERENCES subcontract_order_items(id) ON DELETE RESTRICT,
    line_no                     INTEGER,
    parent_goods_id             UUID NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,  -- 父件=订货货品
    parent_color_id             UUID REFERENCES colors(id) ON DELETE RESTRICT,
    goods_id                    UUID NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,  -- 子件=待发材料
    color_id                    UUID REFERENCES colors(id) ON DELETE RESTRICT,
    unit_id                     UUID REFERENCES units(id) ON DELETE RESTRICT,
    unit_rate                   NUMERIC(18,6) NOT NULL DEFAULT 1 CHECK (unit_rate > 0),
    bom_unit_qty                NUMERIC(18,6) NOT NULL CHECK (bom_unit_qty > 0),        -- 冻结 BOM 单耗
    planned_qty                 NUMERIC(18,4) NOT NULL CHECK (planned_qty > 0),         -- 计划出仓量
    issued_qty                  NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (issued_qty >= 0), -- 已出仓（审核回写）
    remark                      TEXT,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by                  UUID REFERENCES users(id) ON DELETE SET NULL,
    updated_by                  UUID REFERENCES users(id) ON DELETE SET NULL,
    is_deleted                  BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at                  TIMESTAMPTZ,
    CHECK (issued_qty <= planned_qty)
);

CREATE INDEX idx_subcontract_material_plan_items_plan
    ON subcontract_material_plan_items(plan_id) WHERE is_deleted = FALSE;
CREATE INDEX idx_subcontract_material_plan_items_order_item
    ON subcontract_material_plan_items(order_item_id) WHERE is_deleted = FALSE;
CREATE INDEX idx_subcontract_material_plans_status
    ON subcontract_material_plans(status, created_at) WHERE is_deleted = FALSE;

COMMENT ON TABLE subcontract_material_plans IS
    '委外发料计划：财务批准订货同事务按当时 BOM 展开的出仓权威依据；一单一计划；进度口径=计划量/已出仓/待出仓';
COMMENT ON TABLE subcontract_material_plan_items IS
    '委外发料计划行（父件→子件，冻结 BOM 单耗）；issued_qty 由出仓单审核/红冲对称回写，CHECK 不超计划';

-- ② 出仓单明细挂计划行（历史手工单为 NULL）
ALTER TABLE subcontract_material_issue_items
    ADD COLUMN IF NOT EXISTS plan_item_id UUID
        REFERENCES subcontract_material_plan_items(id) ON DELETE RESTRICT;
CREATE INDEX IF NOT EXISTS idx_subcontract_material_issue_items_plan_item
    ON subcontract_material_issue_items(plan_item_id) WHERE plan_item_id IS NOT NULL;
COMMENT ON COLUMN subcontract_material_issue_items.plan_item_id IS
    '来源发料计划行（V304）；计划生成的出仓单必填，审核/红冲据此回写 plan_items.issued_qty；历史手工单为 NULL';

-- ③ 损耗扣款（向委外商追偿；默认 0 = 公司承担）
ALTER TABLE subcontract_wastes
    ADD COLUMN IF NOT EXISTS deduct_amount NUMERIC(18,4),
    ADD COLUMN IF NOT EXISTS deduct_posted BOOLEAN NOT NULL DEFAULT FALSE;
COMMENT ON COLUMN subcontract_wastes.deduct_amount IS
    '损耗扣款金额（本币，向委外商追偿）；NULL/0=公司自行承担不立账；>0 审核立负应付（AP/SUBCONTRACT_WASTE）';
COMMENT ON COLUMN subcontract_wastes.deduct_posted IS
    '损耗扣款是否已立负应付；红冲先反立账（已核销拒）';

-- 应付台账来源类型放行损耗扣款（V57 定义 CHECK 白名单，新增 SUBCONTRACT_WASTE）
ALTER TABLE ar_ap_ledger DROP CONSTRAINT IF EXISTS ar_ap_ledger_source_doc_type_chk;
ALTER TABLE ar_ap_ledger ADD CONSTRAINT ar_ap_ledger_source_doc_type_chk
    CHECK (source_doc_type = ANY (ARRAY[
        'SALES_SHIPMENT', 'SALES_RETURN', 'PURCHASE_RECEIPT', 'PURCHASE_RETURN',
        'SUBCONTRACT_RECEIPT', 'SUBCONTRACT_RETURN', 'SUBCONTRACT_WASTE',
        'DIRECT_RECEIPT', 'DIRECT_PAYMENT']));

-- 审计触发器（与 V289 sweep 口径一致：每张 public 业务表恰一个 AFTER ROW I/U/D fn_audit 触发器）
CREATE TRIGGER trg_audit_subcontract_material_plans
    AFTER INSERT OR UPDATE OR DELETE ON subcontract_material_plans
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_subcontract_material_plan_items
    AFTER INSERT OR UPDATE OR DELETE ON subcontract_material_plan_items
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- ④ 仓库执行权限（只追加不回收，幂等）：出仓/成品退/材料退/损耗记录查看。
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d
JOIN permissions p ON p.code IN (
    'subcontract_material_issue:view',
    'subcontract_material_issue:edit',
    'subcontract_return:view',
    'subcontract_return:edit',
    'subcontract_material_return:view',
    'subcontract_material_return:edit',
    'subcontract_waste:view'
)
WHERE d.code = 'SUB_WH' AND d.is_deleted = FALSE
ON CONFLICT DO NOTHING;
