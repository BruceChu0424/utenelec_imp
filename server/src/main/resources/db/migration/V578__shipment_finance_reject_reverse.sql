-- V578 出货财务审核「撤回退回」支持。
--
-- 背景（2026-09-14 用户实测）：财务退回出货单后，单据从财务「待审核」列表消失、
-- 销售侧「确认并提交财务」按钮被隐藏，退回通知又要求归属人同时持有
-- view+edit 权限才投递——三层叠加导致退回后的单据在两侧都找不到入口，
-- 等价于流程卡死。修复补齐两个出口：
--   1) 财务侧「撤回退回」（本迁移扩展事件类型 + 服务端 financeRejectReverse）；
--   2) 销售侧未改单直接重新提交（confirmSales 放开 financeRejected 分支）。
-- 事件类型新增 REJECT_REVOKED：财务撤回自己的退回决定，单据恢复待财务审核。

ALTER TABLE sales_shipment_finance_release_events
    DROP CONSTRAINT sales_shipment_finance_release_event_type_chk;
ALTER TABLE sales_shipment_finance_release_events
    ADD CONSTRAINT sales_shipment_finance_release_event_type_chk
        CHECK(event_type IN ('RELEASED','REVOKED','REJECTED','REJECT_REVOKED'));

COMMENT ON CONSTRAINT sales_shipment_finance_release_event_type_chk
    ON sales_shipment_finance_release_events IS
    'RELEASED=放行 REVOKED=撤回放行 REJECTED=退回销售 REJECT_REVOKED=撤回退回（V578）';
