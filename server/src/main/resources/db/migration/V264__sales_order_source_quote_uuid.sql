-- 报价 -> 订货运行时关系改为 UUID；source_doc_no 仅保留创建当时的可读单号快照。
ALTER TABLE sales_orders
    ADD COLUMN source_quote_id UUID;

-- 历史 source_doc_no 是通用自由文本；即便单号唯一，也不能证明订单确由报价转换。
-- 因此不按编号猜测或自动回填。历史关系需由转换审计/人工对账后另行确认；
-- V264 起所有在线转换只写 source_quote_id，source_doc_no 仅保留可读快照。

CREATE INDEX idx_sales_orders_source_quote_id
    ON sales_orders(source_quote_id)
    WHERE source_quote_id IS NOT NULL;

-- 新写的一份报价最多只能转换成一份活动订货单；历史歧义行因未回填而不阻塞升级。
CREATE UNIQUE INDEX uq_sales_orders_active_source_quote
    ON sales_orders(source_quote_id)
    WHERE source_quote_id IS NOT NULL AND COALESCE(is_deleted, false) = false;

ALTER TABLE sales_orders
    ADD CONSTRAINT fk_sales_orders_source_quote
        FOREIGN KEY (source_quote_id) REFERENCES sales_quotes(id)
        ON DELETE RESTRICT NOT VALID;

ALTER TABLE sales_orders VALIDATE CONSTRAINT fk_sales_orders_source_quote;

COMMENT ON COLUMN sales_orders.source_quote_id IS
    '来源报价 UUID 真源；source_doc_no 仅为转换时的报价单号快照';
