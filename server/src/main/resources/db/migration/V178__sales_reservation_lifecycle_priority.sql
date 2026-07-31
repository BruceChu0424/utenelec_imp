-- =====================================================================
-- V178：销售成品预留 · 生命周期 + 稀缺仲裁（业务链 V90 增强）
-- =====================================================================
-- 依据：docs/07-业务链路/05-销售现货预留生命周期与稀缺仲裁.md
--   对标 SAP ATP / OMBN 保留期 / backorder processing（研究报告已落地）。
--
-- 三个缺口（均加法，不动存量数据）：
--   A 预留生命周期：stock_reservations 加 hold_until（可选覆盖）。
--       null = 用默认(订单交货日 + 宽限期)动态计算，**不做回填**——避免回填
--       大表、且订单改交期后 hold_until 自动跟随不过期（对齐 SAP 按需求日期 BDTER）。
--       过期清理对标 SAP RM07RVER：每日扫描调度器（ReservationHoldScheduler），
--       默认只通知不自动释放（数据安全：释放须同步回写 sales_order_items 才不漂移，
--       自动释放的编排留后续 opt-in）。
--   B 稀缺仲裁：sales_order_items 加 priority（source of truth 在订单行）。
--       默认 3 现货；急单=1 需权限+原因+审计。不做自动抢占——走手动让单(yield)，
--       释放被让单方预留→chain_status 回退待排产→通知其销售（对标 SAP V_V2/CO06）。
--   C 安全库存进销售 ATP：在 StockReservationRepository.globalAvailableBase 查询里扣
--       goods.min_qty（对齐生产侧 MrpService「当前可用=账面−销售预留−安全库存，最小0」，
--       保守按颜色分别应用）。此处无 DDL，仅文档化，见仓库代码。
--
-- 数据安全：
--   * hold_until 可空，无 DEFAULT、无回填 → 存量行全 null（=用动态默认），零存量变更。
--   * priority NOT NULL DEFAULT 3 → PG11+ 元数据级填充，不重写大表；存量行全=3（现货），
--     对现有分配零行为影响（priority 仅在新的手动让单时生效）。
--   * 新权限不自动授予任何部门（安全第一：敏感操作，超管恒有，管理员分配给主管）。
-- =====================================================================

-- ---------- A) 预留持有截止（可选覆盖） ----------
ALTER TABLE stock_reservations ADD COLUMN IF NOT EXISTS hold_until TIMESTAMPTZ;
COMMENT ON COLUMN stock_reservations.hold_until IS
    '预留持有截止（可选覆盖）：NULL=用默认(订单交货日+宽限期)动态算，免回填且交期改后不过期；非NULL=大客户长单等自定义截止。调度器据此判定是否过期通知';

-- 便于调度器扫描过期未释放的生效预留（status=0 且仍有生效量）
CREATE INDEX IF NOT EXISTS idx_sr_hold_until ON stock_reservations(hold_until)
    WHERE is_deleted = FALSE AND status = 0;

-- ---------- B) 订单行优先级（稀缺重排） ----------
ALTER TABLE sales_order_items ADD COLUMN IF NOT EXISTS priority SMALLINT NOT NULL DEFAULT 3;
COMMENT ON COLUMN sales_order_items.priority IS
    '订单行优先级（稀缺重排用）：1急单/2普通/3现货(默认)；急单需 sales_order:priority 权限+原因+审计。让单时低优先级行的预留可被释放回退待排产';

-- 仅急单/普通行需要进稀缺视图索引（现货=3 不进）
CREATE INDEX IF NOT EXISTS idx_soi_priority ON sales_order_items(priority)
    WHERE is_deleted = FALSE AND priority < 3;

-- ---------- 权限点（契约 §五：销售管理 200-279 段） ----------
-- sales_order:priority  —— 设置订单急单优先级（敏感，不自动授予）
-- sales_order:reallocate —— 稀缺库存让单重排（释放低优先级预留，敏感，不自动授予）
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('sales_order:priority',   '设置订单急单优先级', '销售管理', 214),
    ('sales_order:reallocate', '稀缺库存让单重排',   '销售管理', 215)
ON CONFLICT (code) DO NOTHING;
-- 不自动授予任何部门：超管恒有；由管理员按需分配给销售主管/PMC调度（安全第一）。
