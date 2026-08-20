-- =====================================================================
-- 货品主档迁移：CSV → goods（不依赖 server 启动）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --goods-data
-- 前提：goods 表已存在（V32 由 server Flyway 创建）。
-- 来源：老库 B_Goods（35750 条），category_id 关联 material_categories.legacy_id
--   （B_Goods.ParentID → SystemItem.ItemID）。image 字段不迁（建列留空）。
-- staging 用真实类型，COPY csv 自动 cast + 空字段→null。
-- =====================================================================

BEGIN;
SELECT set_config('app.business_identifier_legacy_import', 'on', true);
-- FK RESTRICT is intentional: an individual master reload must refuse to erase
-- goods already used by documents, stock, production, BOM or analysis rows.
DELETE FROM goods;

CREATE TEMP TABLE goods_stage (
    legacy_id int, code text, name text, short_name text, model text, spec text,
    parent_legacy int,
    unit_legacy_id int, color_legacy_id int, mould_legacy_id int, client_legacy_id int,
    vend_legacy_id int, vend2_legacy_id int, assteam_legacy_id int, veil_legacy_id int,
    approver_legacy_id int, make_legacy_id int,
    price double precision, a_price numeric(18,4), price2 numeric(18,4),
    max_qty double precision, min_qty double precision,
    init_stock int, init_count numeric(18,4), init_weight numeric(18,4),
    kqty numeric(18,4), kqty2 numeric(18,4), pieces int, lost_rate numeric(18,4), cap double precision,
    material text, thickness numeric(18,4), l_style text, z_weight numeric(18,4), m_weight numeric(18,4),
    pack text, b_pack text, paper text, series text, chart_id text, lights text,
    stock_place text, c_number text, v_number text, bs_test text, require_remark text,
    source_e numeric(18,4), work_e numeric(18,4), lacquer_e numeric(18,4), incidental_e numeric(18,4),
    plating_e numeric(18,4), casing_e numeric(18,4), manage_e numeric(18,4), polish_e numeric(18,4),
    electric_e numeric(18,4), machining_e numeric(18,4), lost_e numeric(18,4), rent_e numeric(18,4),
    make_e numeric(18,4), work_rate numeric(18,4), make_rate numeric(18,4), rent_rate numeric(18,4),
    total numeric(18,4), c_total numeric(18,4), g_total numeric(18,4),
    bom_status boolean, status text, app_status int, app_status2 int, g_style int, ck int, zk numeric(18,4)
);
\copy goods_stage FROM '/tmp/goods.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

WITH numbered AS (
    SELECT gs.*,
           row_number() OVER (ORDER BY gs.legacy_id) AS seq_ordinal,
           count(*) OVER ()::bigint AS allocation_count
    FROM goods_stage gs
), reserved AS (
    INSERT INTO category_master_code_sequences (master_type, last_seq)
    SELECT 'GOODS', COALESCE(max(allocation_count), 0) FROM numbered
    ON CONFLICT (master_type) DO UPDATE
    SET last_seq = category_master_code_sequences.last_seq + EXCLUDED.last_seq
    RETURNING last_seq
)
INSERT INTO goods (
    legacy_id, category_id, code, name, short_name, model, spec,
    unit_legacy_id, color_legacy_id, mould_legacy_id, client_legacy_id,
    vend_legacy_id, vend2_legacy_id, assteam_legacy_id, veil_legacy_id,
    approver_legacy_id, make_legacy_id,
    unit_id, color_id, mould_id, client_id,
    default_supplier_id, secondary_supplier_id,
    price, a_price, price2, max_qty, min_qty, init_stock, init_count, init_weight,
    kqty, kqty2, pieces, lost_rate, cap,
    material, thickness, l_style, z_weight, m_weight, pack, b_pack, paper, series,
    chart_id, lights, stock_place, c_number, v_number, bs_test, require_remark,
    source_e, work_e, lacquer_e, incidental_e, plating_e, casing_e, manage_e,
    polish_e, electric_e, machining_e, lost_e, rent_e, make_e, work_rate, make_rate,
    rent_rate, total, c_total, g_total, bom_status, status, app_status, app_status2,
    g_style, ck, zk, code_managed, code_sequence
)
SELECT
    gs.legacy_id,
    (SELECT c.id FROM material_categories c WHERE c.legacy_id = gs.parent_legacy),
    gs.code, gs.name, gs.short_name, gs.model, gs.spec,
    -- 颜色/单位 legacy 快照列同样把老库「未设置」哨兵 0 归一为 NULL（同 V303），
    -- 否则列表/facets 的悬空引用兜底会把 0 渲染成 "#0"。
    NULLIF(gs.unit_legacy_id, 0), NULLIF(gs.color_legacy_id, 0), gs.mould_legacy_id, gs.client_legacy_id,
    gs.vend_legacy_id, gs.vend2_legacy_id, gs.assteam_legacy_id, gs.veil_legacy_id,
    gs.approver_legacy_id, gs.make_legacy_id,
    (SELECT u.id FROM units u WHERE u.legacy_id = NULLIF(gs.unit_legacy_id, 0)),
    (SELECT c.id FROM colors c WHERE c.legacy_id = NULLIF(gs.color_legacy_id, 0)),
    (SELECT m.id FROM moulds m WHERE m.legacy_id = NULLIF(gs.mould_legacy_id, 0)),
    (SELECT c.id FROM clients c WHERE c.legacy_id = NULLIF(gs.client_legacy_id, 0)),
    (SELECT s.id FROM suppliers s WHERE s.legacy_id = NULLIF(gs.vend_legacy_id, 0)),
    (SELECT s.id FROM suppliers s WHERE s.legacy_id = NULLIF(gs.vend2_legacy_id, 0)),
    gs.price, gs.a_price, gs.price2, gs.max_qty, gs.min_qty,
    gs.init_stock, gs.init_count, gs.init_weight, gs.kqty, gs.kqty2,
    gs.pieces, gs.lost_rate, gs.cap,
    gs.material, gs.thickness, gs.l_style, gs.z_weight, gs.m_weight,
    gs.pack, gs.b_pack, gs.paper, gs.series, gs.chart_id, gs.lights,
    gs.stock_place, gs.c_number, gs.v_number, gs.bs_test, gs.require_remark,
    gs.source_e, gs.work_e, gs.lacquer_e, gs.incidental_e, gs.plating_e, gs.casing_e,
    gs.manage_e, gs.polish_e, gs.electric_e, gs.machining_e, gs.lost_e, gs.rent_e,
    gs.make_e, gs.work_rate, gs.make_rate, gs.rent_rate, gs.total, gs.c_total, gs.g_total,
    gs.bom_status, gs.status, gs.app_status, gs.app_status2, gs.g_style, gs.ck, gs.zk,
    FALSE, reserved.last_seq - gs.allocation_count + gs.seq_ordinal
FROM numbered gs CROSS JOIN reserved;

COMMIT;

SELECT '✔ 货品 ' || count(*) ||
       '，已挂分类 ' || count(category_id) ||
       '，未挂分类 ' || count(*) FILTER (WHERE category_id IS NULL) AS 结果
FROM goods;
