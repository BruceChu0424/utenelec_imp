-- V290: 销售出货物流单号（SOP 01 §三.7：一张出货单一个物流单号；分批部分发货会产生
-- 多张出货单多个单号，订单详情须聚合展示全部物流单号，不能只存一个）。
--
-- 纯增量可空列：历史出货单不回填（物流单号是发货后的运营事实，不伪造）；草稿/审核均可
-- 由归属销售维护；红冲单据的编辑仍受既有状态机约束（仅草稿可编辑，见 SalesShipmentService）。
-- 不建第二套"物流明细/件级"表——完整 WMS 物流件级明细仍是明确的未落地项，不得把本列
-- 误写成物流管理体系。

ALTER TABLE sales_shipments
    ADD COLUMN IF NOT EXISTS logistics_no TEXT;

COMMENT ON COLUMN sales_shipments.logistics_no IS
    '物流/快递单号（一张出货单一个；订单详情聚合展示该订单全部出货单的物流单号）';
