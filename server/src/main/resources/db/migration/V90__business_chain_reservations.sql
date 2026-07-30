-- =====================================================================
-- V90：业务链 · 库存软预留台账 + 计划×订单多对多联动 + 订单行链路数量
-- =====================================================================
-- 依据：docs/07-业务链路/01-销售订货到发货全链路-SOP.md（纠正 2 / 纠正 4）
--   纠正 4：库存"软预留"是全新机制。当前库存=流水+余额（V45），无预留概念，
--           本迁移建立 stock_reservations 台账，全系统统一可用库存口径：
--               可用库存 = stock_balances.qty − 生效中预留(qty−consumed−released)
--   纠正 2：不新造"生产任务单"，合并生产落地为 plan_order_item_links
--           （生产计划明细 × 销售订货明细 多对多），与 MRP-lite 同计划单共存。
--
-- 生命周期（Service 层维护，全链对称，漏一环即库存漂移）：
--   产生：订货单审核（现货 source=0）/ 生产入库审核（补产 source=1）
--   消耗：出货单审核 → consumed_qty += 出货量（同时释放占用，库存真出库）
--   释放：订单改量/取消、出货驳回 → released_qty += 差额
--   完结：consumed+released = qty → status=1（Service 派生置位）
--
-- 单位约定：qty/consumed_qty/released_qty 一律**基本单位量**（创建时 qty×unit_rate
--   换算），与 stock_balances.qty / stock_movements.qty 同口径，直接相减。
--
-- 仓库维度（SOP 开放问题 2 的落地）：
--   warehouse_id 可空 = **全局预留**（下单审核时还不知道从哪个仓出，先占全局可用量）；
--   出货开单选定仓库后 Service 改绑具体仓。可用量视图对 NULL 仓预留在每个仓都扣减
--   （保守口径：任何仓都不能把这批货再卖给别人）。
--
-- 跨模块约束（契约 §一）：order_item_id → sales_order_items.id 属跨模块，
--   不建 REFERENCES，仅逻辑 FK + 索引 + 注释（同 V55 sales_order_item_id 先例）。
--   goods/color/warehouse 为主档，正常 FK。
--
-- 历史数据：迁移期老订单一律 chain_status=0（未启动链路）、无预留行；
--   预留与联动只服务新业务，不回填历史（老库本就无预留概念）。
-- =====================================================================

-- ====================== 1) 销售订货明细：链路数量 + 行状态 ======================
-- 与既有 shipped_qty/returned_qty/flag_qty 同族（V51），均为 Service 回写量、行单位量。
ALTER TABLE sales_order_items ADD COLUMN IF NOT EXISTS reserved_qty  NUMERIC(18,4) NOT NULL DEFAULT 0;
ALTER TABLE sales_order_items ADD COLUMN IF NOT EXISTS planned_qty   NUMERIC(18,4) NOT NULL DEFAULT 0;
ALTER TABLE sales_order_items ADD COLUMN IF NOT EXISTS produced_qty  NUMERIC(18,4) NOT NULL DEFAULT 0;
ALTER TABLE sales_order_items ADD COLUMN IF NOT EXISTS chain_status  SMALLINT NOT NULL DEFAULT 0;

COMMENT ON COLUMN sales_order_items.reserved_qty IS
    '当前生效预留量（行单位）：现货审核预留 + 生产入库补预留，出货/取消/驳回时扣减；可发货量=reserved_qty';
COMMENT ON COLUMN sales_order_items.planned_qty IS
    '已排产量（行单位）：plan_order_item_links.allocated_qty 聚合回写（计划红冲/取消回退）';
COMMENT ON COLUMN sales_order_items.produced_qty IS
    '累计完工入库量（行单位）：生产入库审核回写（含补产）；不合格缺额不计';
COMMENT ON COLUMN sales_order_items.chain_status IS
    '链路行状态（Service 派生）：0未启动(迁移历史)/1部分预留/2待排产/3待物料/4已排产/5生产中/6部分完工/7可发货/8部分发货/9已发货/-1已取消';

CREATE INDEX IF NOT EXISTS idx_soi_chain ON sales_order_items(chain_status)
    WHERE is_deleted = FALSE AND chain_status > 0;

-- ====================== 2) 库存软预留台账 ======================
CREATE TABLE IF NOT EXISTS stock_reservations (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 归属：销售订货明细（跨模块逻辑 FK，契约 §一不建 REFERENCES）
    order_item_id   UUID NOT NULL,                       -- → sales_order_items.id（逻辑 FK + 索引）
    -- 库存维度（主档真 FK；冗余自订货明细，免 JOIN 即可算可用量）
    goods_id        UUID NOT NULL REFERENCES goods(id),
    color_id        UUID REFERENCES colors(id),
    warehouse_id    UUID REFERENCES warehouses(id),      -- NULL=全局预留（见头注释仓库维度）
    -- 数量（基本单位；effective = qty − consumed_qty − released_qty）
    qty             NUMERIC(18,4) NOT NULL,
    consumed_qty    NUMERIC(18,4) NOT NULL DEFAULT 0,    -- 已转出库消耗（出货审核回写）
    released_qty    NUMERIC(18,4) NOT NULL DEFAULT 0,    -- 已释放（改量/取消/驳回回写）
    status          SMALLINT NOT NULL DEFAULT 0,         -- 0生效 / 1已完结（Service 派生）
    -- 溯源
    source          SMALLINT NOT NULL DEFAULT 0,         -- 0下单现货预留 / 1生产入库预留
    source_doc_type TEXT,                                -- SALES_ORDER / PRODUCTION_INBOUND
    source_doc_id   UUID,                                -- 产生预留的单据 id
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    CHECK (qty > 0),
    CHECK (consumed_qty >= 0 AND released_qty >= 0),
    CHECK (consumed_qty + released_qty <= qty)
);

-- 按订单行聚合回写 reserved_qty（最频繁）
CREATE INDEX IF NOT EXISTS idx_sr_orderitem ON stock_reservations(order_item_id)
    WHERE is_deleted = FALSE;
-- 可用库存计算：仓+货+色聚合生效预留
CREATE INDEX IF NOT EXISTS idx_sr_stock ON stock_reservations(warehouse_id, goods_id, color_id)
    WHERE is_deleted = FALSE AND status = 0;
-- 全局预留（warehouse_id IS NULL）单独走索引
CREATE INDEX IF NOT EXISTS idx_sr_global ON stock_reservations(goods_id, color_id)
    WHERE is_deleted = FALSE AND status = 0 AND warehouse_id IS NULL;

COMMENT ON TABLE stock_reservations IS
    '库存软预留台账（业务链核心）：可用库存=stock_balances.qty−Σ(qty−consumed−released)；warehouse_id NULL=全局预留；数量一律基本单位';
COMMENT ON COLUMN stock_reservations.order_item_id IS
    '→ sales_order_items.id（跨模块逻辑 FK，契约 §一不建 REFERENCES）';
COMMENT ON COLUMN stock_reservations.consumed_qty IS
    '出货审核消耗（真出库后预留使命完成）；与 released_qty 互斥累计，合计不超 qty';

-- ====================== 3) 可用库存视图（统一口径，全链路唯一事实源） ======================
-- 下单校验 / 排产 / 出货校验一律读此视图，禁止各写各的减法。
-- NULL 仓预留在每个仓都扣（保守）；「全部仓」聚合查询时全局预留只应扣一次，
-- 聚合口径由 Service 单独 SUM 处理（视图按仓行展示）。
CREATE OR REPLACE VIEW v_stock_available AS
SELECT b.warehouse_id,
       b.goods_id,
       b.color_id,
       b.qty                       AS on_hand_qty,
       b.weight                    AS on_hand_weight,
       COALESCE(r.reserved_qty, 0) AS reserved_qty,
       b.qty - COALESCE(r.reserved_qty, 0) AS available_qty
FROM stock_balances b
LEFT JOIN (
    SELECT warehouse_id, goods_id, color_id,
           SUM(qty - consumed_qty - released_qty) AS reserved_qty
    FROM stock_reservations
    WHERE is_deleted = FALSE AND status = 0
    GROUP BY warehouse_id, goods_id, color_id
) r
  ON r.goods_id = b.goods_id
 AND r.color_id IS NOT DISTINCT FROM b.color_id
 AND (r.warehouse_id = b.warehouse_id OR r.warehouse_id IS NULL);

COMMENT ON VIEW v_stock_available IS
    '可用库存统一口径：账面 − 生效预留（基本单位）；全局预留(NULL仓)在每个仓保守扣减';

-- ====================== 4) 生产计划明细 × 销售订货明细 联动（合并生产） ======================
-- 多对多：一个计划行可合并多个订单行（100+50=150）；一个订单行可拆到多个计划行（分批）。
-- 与既有 production_plan_items.sales_order_item_id（老库单值软关联）并存：
--   老字段只用于迁移溯源；新业务联动一律走本表。
CREATE TABLE IF NOT EXISTS plan_order_item_links (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_item_id    UUID NOT NULL REFERENCES production_plan_items(id) ON DELETE CASCADE,
    order_item_id   UUID NOT NULL,                       -- → sales_order_items.id（跨模块逻辑 FK）
    allocated_qty   NUMERIC(18,4) NOT NULL,              -- 本计划行分给该订单行的排产量（行单位）
    produced_qty    NUMERIC(18,4) NOT NULL DEFAULT 0,    -- 报工合格量回写
    inbound_qty     NUMERIC(18,4) NOT NULL DEFAULT 0,    -- 完工入库量回写（入库即补预留）
    source          SMALLINT NOT NULL DEFAULT 0,         -- 0正常排产 / 1补产（关联原计划见 remark）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID, updated_by UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE, deleted_at TIMESTAMPTZ,
    CHECK (allocated_qty > 0),
    CHECK (produced_qty >= 0 AND inbound_qty >= 0)
);

-- 防重复：同一计划行×订单行只允许一条未删除联动（幂等，同 V87/V88 规则）
CREATE UNIQUE INDEX IF NOT EXISTS uq_pol_pair ON plan_order_item_links(plan_item_id, order_item_id)
    WHERE is_deleted = FALSE;
CREATE INDEX IF NOT EXISTS idx_pol_orderitem ON plan_order_item_links(order_item_id)
    WHERE is_deleted = FALSE;

COMMENT ON TABLE plan_order_item_links IS
    '生产计划明细×销售订货明细 多对多联动：合并生产/分批排产/补产；planned/produced/inbound 三量沿本表回写订单行';
COMMENT ON COLUMN plan_order_item_links.order_item_id IS
    '→ sales_order_items.id（跨模块逻辑 FK，契约 §一不建 REFERENCES）';
COMMENT ON COLUMN plan_order_item_links.source IS
    '0正常排产 / 1补产（不良缺额自动生成，remark 记原计划单号）';

-- ====================== 5) 权限点（契约 §五：销售管理 200-279 段内顺延） ======================
-- sales_order:price:view —— 价格脱敏：生产/仓库默认不授予，列表/详情/导出统一脱敏
--   （沿用 V30 pgcrypto 脱敏按权限点机制）。
-- 注：「查看全部订单」不另建——V91 已统一为 sales:view:all（覆盖四张销售单据，同 V85/V86 模式）。
-- 顺带清理本迁移早期版本曾插入的 sales_order:view:all（幂等删除，未启用过）。
DELETE FROM department_permissions WHERE permission_id IN
    (SELECT id FROM permissions WHERE code = 'sales_order:view:all');
DELETE FROM permissions WHERE code = 'sales_order:view:all';

INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('sales_order:price:view','查看订单价格',     '销售管理', 213)
ON CONFLICT (code) DO NOTHING;

-- 价格查看默认只给综合营销部（生产/仓库不授予即脱敏；超管恒有）
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id FROM departments d, permissions p
WHERE d.code = 'DEPT_SALES'
  AND p.code = 'sales_order:price:view'
ON CONFLICT DO NOTHING;
