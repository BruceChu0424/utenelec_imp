-- V812: 页面权限面层级(hub 包拢子页面) + 权限入口缺口收口。
--
-- ① permission_surfaces 增加 parent_surface_key：hub 面(销售/采购/委外/生产/仓库/
--    钱流/基础资料)挂子面后，页面右上角权限抽屉可以「父+子」一站式设置(ADR-162)。
--    层级只允许一层(hub → 卡片面)；码在树内按「子面优先」归组展示，根面只保留
--    没有被任何子面认领的码。
-- ② 三张任务中心面合并为一张 warehouse.tasks(2026-09-24 四卡合并页之后的目录对齐)：
--    旧 outbound/inbound/draw 三面是同一张页面的三个入口，委派面也该是一张。
--    既有委派行的 surface_key 原地重写，避免解析器 fail-closed 静默失效。
-- ③ production.workshop-material 是无路由孤儿面(车间侧内料仓动作实际发生在
--    /production/workshop-tasks 内嵌面板)，其码并入 production.workshop-tasks。
-- ④ 新面补齐「有页面无权限面」缺口：sales.tasks(销售任务中心)、warehouse.tasks
--    (仓库任务中心合并页)、finance.audit-center(财务业务审核中心)。

-- ===== ① 层级列 =====
ALTER TABLE permission_surfaces
    ADD COLUMN parent_surface_key VARCHAR(128);

ALTER TABLE permission_surfaces
    ADD CONSTRAINT permission_surfaces_parent_fk
        FOREIGN KEY (parent_surface_key)
        REFERENCES permission_surfaces(surface_key);

ALTER TABLE permission_surfaces
    ADD CONSTRAINT permission_surfaces_parent_not_self_chk
        CHECK (parent_surface_key IS NULL OR parent_surface_key <> surface_key);

CREATE INDEX idx_permission_surfaces_parent
    ON permission_surfaces(parent_surface_key)
    WHERE parent_surface_key IS NOT NULL;

COMMENT ON COLUMN permission_surfaces.parent_surface_key IS
    'hub 面的子页面权限面键；仅一层(hub → 卡片面)，子面不得再有子面';

-- ===== ② 旧任务中心三面 → warehouse.tasks（先建新面再搬，最后删旧面）=====
INSERT INTO permission_surfaces(id, surface_key, name, sort_order, enabled) VALUES
    ('81200000-0000-4000-8000-000000000001', 'sales.tasks', '销售任务中心', 35, TRUE),
    ('81200000-0000-4000-8000-000000000002', 'warehouse.tasks', '仓库任务中心', 89, TRUE),
    ('81200000-0000-4000-8000-000000000003', 'finance.audit-center', '财务业务审核中心', 72, TRUE);

-- sales.tasks：任务中心路由守卫的五个单据查看码并集。
WITH mapping(surface_key, permission_code) AS (VALUES
    ('sales.tasks', 'sales_quote:view'),
    ('sales.tasks', 'sales_order:view'),
    ('sales.tasks', 'sales_shipment:view'),
    ('sales.tasks', 'sales_other_shipment:view'),
    ('sales.tasks', 'sales_return:view'),
    -- warehouse.tasks：原三张任务面(87/88/89)码并集。
    ('warehouse.tasks', 'stock_doc:view'),
    ('warehouse.tasks', 'stock_doc:view:all'),
    ('warehouse.tasks', 'stock_doc:create'),
    ('warehouse.tasks', 'stock_doc:edit'),
    ('warehouse.tasks', 'stock_doc:delete'),
    ('warehouse.tasks', 'stock_doc:approve'),
    ('warehouse.tasks', 'stock_doc:issue'),
    ('warehouse.tasks', 'stock_doc:reverse'),
    ('warehouse.tasks', 'stock_doc:reverse_issue'),
    ('warehouse.tasks', 'production_finished_in:before_inspection'),
    ('warehouse.tasks', 'warehouse_inbound:view'),
    ('warehouse.tasks', 'warehouse_inbound:stock_in'),
    ('warehouse.tasks', 'warehouse_iqc_stock_in:before_inspection'),
    ('warehouse.tasks', 'warehouse_purchase_receipt_history:view'),
    ('warehouse.tasks', 'warehouse_subcontract_receipt_history:view'),
    ('warehouse.tasks', 'subcontract_outbound:view'),
    ('warehouse.tasks', 'subcontract_outbound:execute'),
    ('warehouse.tasks', 'warehouse_sales_outbound:view'),
    ('warehouse.tasks', 'warehouse_sales_outbound:execute'),
    -- finance.audit-center：业务审核中心路由守卫的四个查看码。
    ('finance.audit-center', 'sales_order_finance:view'),
    ('finance.audit-center', 'sales_shipment_finance:view'),
    ('finance.audit-center', 'finance_order_approval:view'),
    ('finance.audit-center', 'procurement_iqc_rejection:view'))
INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id FROM mapping
JOIN permission_surfaces surface ON surface.surface_key = mapping.surface_key
JOIN permissions permission ON permission.code = mapping.permission_code;

-- ③ production.workshop-material 孤儿面的码并入 production.workshop-tasks。
INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT target.id, permission.id
FROM permission_surfaces target
JOIN permission_surface_permissions link
  ON link.surface_id = (SELECT id FROM permission_surfaces WHERE surface_key = 'production.workshop-material')
JOIN permissions permission ON permission.id = link.permission_id
WHERE target.surface_key = 'production.workshop-tasks'
  AND NOT EXISTS (
      SELECT 1 FROM permission_surface_permissions existing
      WHERE existing.surface_id = target.id
        AND existing.permission_id = link.permission_id);

-- ⑤ 采购申请详情页的「生成订货单/分解」动作依赖订货码，本页面须能委派(V812 前唯一真实挂码缺口)。
INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission ON permission.code IN ('purchase_order:decompose', 'purchase_order:create')
WHERE surface.surface_key = 'purchase.request'
  AND NOT EXISTS (
      SELECT 1 FROM permission_surface_permissions existing
      WHERE existing.surface_id = surface.id
        AND existing.permission_id = permission.id);

-- 既有委派行原地重写 surface_key（先于删面；resolver 只认已知面）。
UPDATE manager_permission_delegations
SET surface_key = 'warehouse.tasks'
WHERE surface_key IN ('warehouse.outbound-tasks', 'warehouse.inbound-tasks', 'warehouse.draw-tasks');

UPDATE manager_permission_delegations
SET surface_key = 'production.workshop-tasks'
WHERE surface_key = 'production.workshop-material';

-- 删孤儿面的码挂载与面本体（链接 FK 为 RESTRICT，须先删链接）。
DELETE FROM permission_surface_permissions
WHERE surface_id IN (SELECT id FROM permission_surfaces WHERE surface_key IN (
    'production.workshop-material',
    'warehouse.outbound-tasks',
    'warehouse.inbound-tasks',
    'warehouse.draw-tasks'));

DELETE FROM permission_surfaces WHERE surface_key IN (
    'production.workshop-material',
    'warehouse.outbound-tasks',
    'warehouse.inbound-tasks',
    'warehouse.draw-tasks');

-- ===== ④ hub → 卡片子面层级（hub_catalog 逐卡核对；子面顺序=sort_order）=====
WITH hierarchy(child_surface_key, parent_surface_key) AS (VALUES
    -- 基础资料：11 张卡片面。
    ('basic.goods', 'basic.hub'),
    ('basic.mould', 'basic.hub'),
    ('basic.client', 'basic.hub'),
    ('basic.supplier', 'basic.hub'),
    ('basic.color', 'basic.hub'),
    ('basic.unit', 'basic.hub'),
    ('basic.currency', 'basic.hub'),
    ('basic.warehouse', 'basic.hub'),
    ('basic.account', 'basic.hub'),
    ('basic.payment-style', 'basic.hub'),
    ('basic.settlement-method', 'basic.hub'),
    -- 销售管理：五类单据卡 + 报表 + 稀缺仲裁 + 任务中心。
    ('sales.quote', 'sales.hub'),
    ('sales.order', 'sales.hub'),
    ('sales.shipment', 'sales.hub'),
    ('sales.other-shipment', 'sales.hub'),
    ('sales.return', 'sales.hub'),
    ('sales.report', 'sales.hub'),
    ('sales.scarcity', 'sales.hub'),
    ('sales.tasks', 'sales.hub'),
    -- 采购管理：履约工作台 + 三类单据卡 + 报表 + 待退回供应商。
    ('operations.purchase', 'purchase.hub'),
    ('purchase.order', 'purchase.hub'),
    ('purchase.receipt', 'purchase.hub'),
    ('purchase.return', 'purchase.hub'),
    ('purchase.report', 'purchase.hub'),
    ('purchase.arrival-exception', 'purchase.hub'),
    -- 委外管理：履约工作台 + 四类单据卡 + 材料出仓 + 报表 + 短交判定。
    -- 「待退回供应商」卡与采购 hub 同页复用，单父模型下归属采购 hub。
    ('operations.subcontract', 'subcontract.hub'),
    ('subcontract.order', 'subcontract.hub'),
    ('subcontract.return', 'subcontract.hub'),
    ('subcontract.material-return', 'subcontract.hub'),
    ('subcontract.waste', 'subcontract.hub'),
    ('subcontract.material-issue', 'subcontract.hub'),
    ('subcontract.report', 'subcontract.hub'),
    -- 生产管理：调度台 + 计划(含超产/补料审批队列) + 日报 + 报表 + 物料反查 + 内料仓报表。
    ('production.schedule', 'production.hub'),
    ('production.plan', 'production.hub'),
    ('production.daily-report', 'production.hub'),
    ('production.report', 'production.hub'),
    ('production.where-used', 'production.hub'),
    ('report.workshop-material', 'production.hub'),
    -- 仓库管理：任务中心 + 库存单据 + 即时库存 + 报表 + 货架 + 库存详情 + 内料仓设置。
    ('warehouse.tasks', 'warehouse.hub'),
    ('warehouse.stock-document', 'warehouse.hub'),
    ('warehouse.instant-inventory', 'warehouse.hub'),
    ('warehouse.report', 'warehouse.hub'),
    ('warehouse.shelf-label', 'warehouse.hub'),
    ('warehouse.stock-item', 'warehouse.hub'),
    ('warehouse.workshop-material-setup', 'warehouse.hub'),
    -- 钱流管理：审核中心 + 核价 + 盘点审核 + 报销 + 五类单据卡 + 支票/资产/应付/报表。
    -- 内料仓用量报表卡与生产 hub 同页复用，单父模型下归属生产 hub。
    ('finance.audit-center', 'finance.hub'),
    ('finance.sales-quote-review', 'finance.hub'),
    ('finance.stock-count-review', 'finance.hub'),
    ('hr.expense', 'finance.hub'),
    ('finance.receipt', 'finance.hub'),
    ('finance.payment', 'finance.hub'),
    ('finance.expense', 'finance.hub'),
    ('finance.other-income', 'finance.hub'),
    ('finance.bank-transfer', 'finance.hub'),
    ('finance.checks', 'finance.hub'),
    ('finance.asset', 'finance.hub'),
    ('finance.payables', 'finance.hub'),
    ('finance.report', 'finance.hub'))
UPDATE permission_surfaces child
SET parent_surface_key = hierarchy.parent_surface_key
FROM hierarchy
WHERE child.surface_key = hierarchy.child_surface_key;

-- ===== 校验：单层、父存在且启用、子面至少挂一码、新面码齐 =====
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM permission_surfaces child
        JOIN permission_surfaces parent ON parent.surface_key = child.parent_surface_key
        WHERE parent.parent_surface_key IS NOT NULL) THEN
        RAISE EXCEPTION '权限面层级只允许一层(hub → 卡片面)';
    END IF;
    IF EXISTS (
        SELECT 1 FROM permission_surfaces child
        WHERE child.parent_surface_key IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM permission_surfaces parent
              WHERE parent.surface_key = child.parent_surface_key
                AND parent.enabled)) THEN
        RAISE EXCEPTION '存在指向未启用或不存在父面的子面';
    END IF;
    IF EXISTS (
        SELECT 1 FROM permission_surfaces child
        WHERE child.parent_surface_key IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM permission_surface_permissions link
              WHERE link.surface_id = child.id)) THEN
        RAISE EXCEPTION '存在没有挂任何权限码的子面';
    END IF;
    IF (SELECT count(*) FROM permission_surface_permissions link
        JOIN permission_surfaces surface ON surface.id = link.surface_id
        WHERE surface.surface_key IN ('sales.tasks', 'warehouse.tasks', 'finance.audit-center')) <> 28 THEN
        RAISE EXCEPTION '三张新面的码挂载数量不符';
    END IF;
    IF EXISTS (SELECT 1 FROM permission_surfaces WHERE surface_key IN (
            'production.workshop-material', 'warehouse.outbound-tasks',
            'warehouse.inbound-tasks', 'warehouse.draw-tasks')) THEN
        RAISE EXCEPTION '被合并的旧权限面未删除干净';
    END IF;
    IF EXISTS (SELECT 1 FROM manager_permission_delegations WHERE surface_key IN (
            'production.workshop-material', 'warehouse.outbound-tasks',
            'warehouse.inbound-tasks', 'warehouse.draw-tasks')) THEN
        RAISE EXCEPTION '仍有委派行指向被合并的旧权限面';
    END IF;
END;
$$;
