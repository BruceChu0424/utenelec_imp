-- Each goods UUID/code has one optional customer-facing product name.
-- Customer model already exists as c_number; no customer alias relationship is added.
ALTER TABLE goods ADD COLUMN client_goods_name text;
COMMENT ON COLUMN goods.client_goods_name IS '客户货品名称；本货品唯一一组可选文本，不以客户公司名或普通货品名猜填';
COMMENT ON COLUMN goods.c_number IS '客户型号；沿用旧库 B_Goods.CNumber，与本货品自身型号独立';

-- Old immutable snapshots predate this nullable field. Compare their missing
-- key with the schema default without rewriting evidence or hiding later edits.
CREATE OR REPLACE FUNCTION fn_goods_bom_history_schema(p_row JSONB,p_table TEXT) RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_row IS NULL THEN NULL
        WHEN p_table='goods' THEN jsonb_build_object('client_goods_name',NULL)||p_row
        WHEN p_table='goods_bom_items' THEN
            jsonb_build_object('retirement_reason',NULL,'retirement_resolved_at',NULL)||p_row
        ELSE p_row END
$$;
