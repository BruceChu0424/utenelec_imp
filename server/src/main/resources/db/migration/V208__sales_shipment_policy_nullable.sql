-- V208: shipment_policy 允许为空——新单默认不填，由销售自选 ALLOW_PARTIAL / REQUIRE_COMPLETE。
--
-- customerConfirm 不再提供给新单（前端 selectable 已移除），但历史单的 CUSTOMER_CONFIRM /
-- LEGACY_UNSPECIFIED 值仍合法，故 CHECK 约束保留四值不变；这里只放宽可空性并去掉默认值，
-- 使"销售未选择"以 NULL 表达。NULL 通过 CHECK（CHECK 对 NULL 放行）。

ALTER TABLE sales_orders
    ALTER COLUMN shipment_policy DROP NOT NULL;
ALTER TABLE sales_orders
    ALTER COLUMN shipment_policy DROP DEFAULT;

COMMENT ON COLUMN sales_orders.shipment_policy IS
    'ALLOW_PARTIAL=允许分批；REQUIRE_COMPLETE=整单齐套；NULL=新单未选择（销售自填）；CUSTOMER_CONFIRM/LEGACY_UNSPECIFIED=历史值，新单不再提供';
