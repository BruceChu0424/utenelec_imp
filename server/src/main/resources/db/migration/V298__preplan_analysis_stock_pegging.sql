-- V298: 计划前物料分析备料库存绑定（pegging）。
--
-- 背景：物料分析下达的采购/委外订货，到货 IQC 合格入库后没有任何预留锚点，
-- 直接成为全系统公共现货（v_stock_available），导致后续新分析的备料缺口把
-- 「别的分析已经买好入库的料」算成自己的可用量（跨分析重复计算）。
-- 跨分析软承诺（softCommittedStock）只覆盖其它分析 depth=1 快照行，深层物料
-- 与「已收货但尚未下达计划」的量完全漏出。
--
-- 设计：收货入库即把入库量按「订货明细 → 申请/委外明细 → 分析供应行动分摊」
-- 溯源到来源分析，写 owner_type='PREPLAN_ANALYSIS' 的库存软预留：
--   - v_stock_available 统一口径自动把它从公共现货中剔除（其它分析/销售/MRP 均不可见）；
--   - 归属分析自己的可用量 = v_stock_available + 本分析生效预留（MaterialAnalysisService 加回）；
--   - 分析下达正式计划包（confirm）时同事务把预留「转移」给需求（先释放分析预留，
--     需求分配器再从池中为 demand 建行），库存事实不重复、不漂移；
--   - 收货红冲 / 分析取消 / 供应行动撤回 → 对称释放；
--   - 自制备料（成品入库单）对无销售链接的计划行产出，同样补分析归属预留。
--
-- 约束扩展只在既有 CHECK 中新增一种归属形态，历史行不受影响、不回填。

ALTER TABLE stock_reservations
    DROP CONSTRAINT stock_reservations_owner_type_chk,
    DROP CONSTRAINT stock_reservations_purpose_chk,
    DROP CONSTRAINT stock_reservations_owner_shape_chk;

ALTER TABLE stock_reservations
    ADD CONSTRAINT stock_reservations_owner_type_chk
        CHECK (owner_type IN (
            'SALES_ORDER_ITEM', 'PRODUCTION_MATERIAL_DEMAND', 'PREPLAN_ANALYSIS')),
    ADD CONSTRAINT stock_reservations_purpose_chk
        CHECK (purpose IN (
            'SALES_FULFILLMENT', 'PRODUCTION_MATERIAL', 'PREPLAN_MATERIAL')),
    ADD CONSTRAINT stock_reservations_owner_shape_chk
        CHECK (
            (
                owner_type = 'SALES_ORDER_ITEM'
                AND purpose = 'SALES_FULFILLMENT'
                AND order_item_id IS NOT NULL
                AND owner_id = order_item_id
                AND demand_id IS NULL
            )
            OR
            (
                owner_type = 'PRODUCTION_MATERIAL_DEMAND'
                AND purpose = 'PRODUCTION_MATERIAL'
                AND order_item_id IS NULL
                AND demand_id IS NOT NULL
                AND owner_id = demand_id
                AND warehouse_id IS NOT NULL
                AND supply_type = 'STOCK_BALANCE'
                AND supply_id IS NOT NULL
                AND idempotency_key IS NOT NULL
            )
            OR
            (
                owner_type = 'PREPLAN_ANALYSIS'
                AND purpose = 'PREPLAN_MATERIAL'
                AND order_item_id IS NULL
                AND demand_id IS NULL
                AND owner_id IS NOT NULL
                AND warehouse_id IS NOT NULL
                AND supply_type IN (
                    'PURCHASE_REQUEST_ITEM',
                    'SUBCONTRACT_APPLICATION_ITEM',
                    'PRODUCTION_PLAN_ITEM')
                AND supply_id IS NOT NULL
                AND idempotency_key IS NOT NULL
            )
        );

-- 按分析回收/转移/释放的高频过滤
CREATE INDEX IF NOT EXISTS idx_stock_reservation_preplan_owner
    ON stock_reservations(owner_id, warehouse_id, goods_id, color_id, status)
    WHERE is_deleted = FALSE AND owner_type = 'PREPLAN_ANALYSIS';

CREATE INDEX IF NOT EXISTS idx_stock_reservation_preplan_supply
    ON stock_reservations(supply_type, supply_id)
    WHERE is_deleted = FALSE AND owner_type = 'PREPLAN_ANALYSIS';

COMMENT ON COLUMN stock_reservations.owner_type IS
    '预留归属：SALES_ORDER_ITEM=销售订单行 / PRODUCTION_MATERIAL_DEMAND=计划包物料需求 / PREPLAN_ANALYSIS=计划前物料分析备料（V298）';
