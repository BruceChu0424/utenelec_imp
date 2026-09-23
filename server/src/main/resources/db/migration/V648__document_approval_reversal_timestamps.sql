-- V648 (ADR-105) 审核/红冲/驳回时间落在单据自己的列上, 业务逻辑不再从审计日志反查。
--
-- 销售订单进度时间线原先用 audit_log 的状态迁移行补「审核时间/红冲时间」, 在线审计只保留
-- 6 个月, 之后时间点会从时间线上消失; 审计改为只存变化键后也不能再当事实源。
-- 状态码口径(代码事实): 1 = 已审核, -1 = 已红冲(STATUS_REVERSED, 不是驳回);
-- 出货单另有仓库驳回(rejected=true), 其时间与驳回人一并落列。
-- 由审核/红冲/驳回命令在同一事务里写入。未上线, 不回填历史。

ALTER TABLE public.sales_orders
    ADD COLUMN approved_at TIMESTAMPTZ,
    ADD COLUMN reversed_at TIMESTAMPTZ,
    ADD COLUMN reversed_by UUID REFERENCES public.employees(id);

ALTER TABLE public.sales_shipments
    ADD COLUMN approved_at TIMESTAMPTZ,
    ADD COLUMN rejected_at TIMESTAMPTZ,
    ADD COLUMN rejected_by UUID REFERENCES public.employees(id),
    ADD COLUMN reversed_at TIMESTAMPTZ,
    ADD COLUMN reversed_by UUID REFERENCES public.employees(id);

ALTER TABLE public.production_plans
    ADD COLUMN approved_at TIMESTAMPTZ,
    ADD COLUMN reversed_at TIMESTAMPTZ,
    ADD COLUMN reversed_by UUID REFERENCES public.employees(id);

COMMENT ON COLUMN public.sales_orders.approved_at IS '最近一次审核通过时间(审核命令写入)';
COMMENT ON COLUMN public.sales_orders.reversed_at IS '红冲时间(红冲命令写入)';
COMMENT ON COLUMN public.sales_orders.reversed_by IS '红冲人(员工)';
COMMENT ON COLUMN public.sales_shipments.approved_at IS '仓库确认出库(审核)时间';
COMMENT ON COLUMN public.sales_shipments.rejected_at IS '仓库驳回时间';
COMMENT ON COLUMN public.sales_shipments.rejected_by IS '仓库驳回人(员工)';
COMMENT ON COLUMN public.sales_shipments.reversed_at IS '红冲时间(红冲命令写入)';
COMMENT ON COLUMN public.sales_shipments.reversed_by IS '红冲人(员工)';
COMMENT ON COLUMN public.production_plans.approved_at IS '最近一次审核下达时间(审核命令写入)';
COMMENT ON COLUMN public.production_plans.reversed_at IS '红冲时间(红冲命令写入)';
COMMENT ON COLUMN public.production_plans.reversed_by IS '红冲人(员工)';
