-- ============ 退役客户货款类别标签 (2026-09-20 用户口径) ============
-- 用户口径: 财务放行看的是销售订单选定、随出货单头一起走的「结账方式」
-- (settlement_methods: 现金/月结/汇款/支票…, 客户资料记住最近一次作为下次默认,
-- V592), 客户资料不再另挂一个「月结/现金/定金」三选一标签。两者语义重叠——字典里
-- 现金/月结本就带 system_role, 而汇款/支票/提货/代付等结账方式根本映射不到三分类,
-- 本地库 260 个客户里 216 个永远停在「待人工分类」, 财审因此被一个 V443 自己都
-- 声明为 informational only、不决定任何事情的标签卡死。
--
-- 本迁移彻底删除该概念:
--   1. clients.sales_payment_type 列 + 值域 CHECK + 部分索引 + V443 迁移异常视图
--      (v_client_sales_payment_type_migration_issues), V607 已删的必填 CHECK 幂等再删;
--   2. sales_shipment_finance_release_events.sales_payment_type 快照列及两条 CHECK
--      (V443 payment_type_chk / V511 released_type_chk)。事件表的结账方式 UUID 快照
--      (settlement_method_id) 保留, 它才是放行当时真实生效的条款。
-- 存量: 该列只有 V443 按 system_role 自动回填的 CASH/MONTHLY 值, 与
-- clients.default_settlement_method_id 承载同一事实, 无需迁移数据; 事件表在所有
-- 环境该列可空且尚无依赖行, 直接 DROP。
-- 应用侧同步: SalesShipmentService 不再 requireClassifiedSalesPaymentType, 财审
-- 快照/放行事件不再携带 salesPaymentType; 客户主档 DTO/facet/导出/前端表单/列表/
-- 详情与财审页同步删除; 应收汇总报表「货款类型」列退役(「结算期限」列已表达结账方式);
-- 旧系统首导脚本不再回填该列, 结构对账由 24 项收为 23 项。

DROP VIEW IF EXISTS v_client_sales_payment_type_migration_issues;

ALTER TABLE clients
    DROP CONSTRAINT IF EXISTS clients_online_sales_payment_type_required_chk,
    DROP CONSTRAINT IF EXISTS clients_sales_payment_type_chk;
DROP INDEX IF EXISTS idx_clients_sales_payment_type;
ALTER TABLE clients DROP COLUMN IF EXISTS sales_payment_type;

ALTER TABLE sales_shipment_finance_release_events
    DROP CONSTRAINT IF EXISTS sales_shipment_finance_release_event_payment_type_chk,
    DROP CONSTRAINT IF EXISTS sales_shipment_finance_release_event_released_type_chk;
ALTER TABLE sales_shipment_finance_release_events DROP COLUMN IF EXISTS sales_payment_type;

-- V511 的 released_type_chk 只表达「RELEASED 事件要么已分类要么是免费单」, 分类退役后
-- 无剩余语义(billing_mode 本身由 fn_guard_customer_shipment_review_event 守), 不重建。

COMMENT ON COLUMN sales_shipment_finance_release_events.settlement_method_id IS
    '放行/撤回当时生效的结账方式 UUID 快照(本单头优先, 否则客户默认); V630 起是事件里唯一的条款事实, 客户货款类别标签已退役';
