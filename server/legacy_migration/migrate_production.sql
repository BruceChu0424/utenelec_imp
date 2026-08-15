-- =====================================================================
-- 生产模块迁移：F_Plan / F_PlanItem / F_PlanCostItem / F_DateReport(+Item)
--   -> production_plans / production_plan_items / production_plan_costs (分区)
--      / production_daily_reports(+items)
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --production
-- 前提：V32-V43 主档（goods/colors/units/suppliers/currencies/warehouses）
--       + V51 sales_order_items + sales_order_cost_items（销售模块必须先迁，跨模块依赖）
--       + V55 生产表已建（含 13 年度分区 + DEFAULT 兜底）。
-- 顺序：production_plans -> production_plan_items -> production_plan_costs
--   （FK 链：costs.bill_item_id 经 plan_items.legacy_id 映射 -> 必须先迁 plan_items）。
-- 重载：按 FK 逆序 DELETE 五张表（分区父表 DELETE 覆盖全部子分区）；
--   任何执行/物料分析/库存证据引用都会在导入前 fail-closed。
-- 人员字段（maker/approver/worker/seller）：employees 与 B_Worker 未对齐，留 NULL
--   + *_legacy_id INT 留底（同采购 migrate_purchase.sql 范式）。
-- status：老库 1=已审 / -1=红冲（无 0 草稿），直接照搬。
-- 库存历史不在此迁（stock_movements/balances 归仓库模块）。
-- 成本重算/触发器逻辑本期不做（design 24 §4.2，保数据只读）。
-- =====================================================================


-- ======================== 0. FK-ordered cleanup ========================
BEGIN;
DELETE FROM production_daily_report_items;
DELETE FROM production_daily_reports;
DELETE FROM production_plan_costs;
DELETE FROM production_plan_items;
DELETE FROM production_plans;
COMMIT;


-- ======================== 1. staging ========================
-- 列顺序必须与 export_production_snippet.ps1 各 SELECT 一致（\copy 按位置匹配）。

CREATE TEMP TABLE plan_stage (
    legacy_id int, bill_no text, bill_date date, f_style text, delivery_date date,
    workshop_name text, worker_name text, seller_name text,
    maker_legacy int, approver_legacy int,
    maker_name text, approver_name text,
    remark text, status smallint,
    fulfill_bit boolean, stop_bit boolean, cancel_bit boolean);
\copy plan_stage FROM '/tmp/production_plans.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE item_stage (
    legacy_id int, plan_legacy_id int, product_no text,
    goods_legacy_id int, color_legacy_id int, mgoods_legacy_id int,
    unit_legacy_id int, unit_rate numeric(18,6),
    s_order_item_legacy int, sales_order_no text, client_name text, client_no text,
    oqty numeric(18,4), qty numeric(18,4), lqty numeric(18,4), iqty numeric(18,4),
    fqty numeric(18,4), rqty numeric(18,4), bqty numeric(18,4), tqty numeric(18,4),
    paqty numeric(18,4), isrqty numeric(18,4), cpqty numeric(18,4),
    poqty numeric(18,4), piqty numeric(18,4),
    order_date date, outbound_date date, plan_begin_date date, plan_end_date date,
    finished_weight numeric(18,4), inbound_weight numeric(18,4),
    lstatus smallint, cstatus smallint,
    step_legacy_id int, veil_legacy_id int, ass_team_legacy_id int, fittings text,
    request_note text, customer_model text, discount numeric(18,4),
    label_no text, plan_app_no text, in_no text, tran_no text, remark text);
\copy item_stage FROM '/tmp/production_plan_items.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- F_PlanCostItem 1.36M 行 / 33 cols（9 个多值溯源号在 export 端已前缀化合并为 source_doc_no）
CREATE TEMP TABLE cost_stage (
    legacy_id int, bill_item_legacy_id int,
    goods_legacy_id int, color_legacy_id int,
    qty numeric(18,4), price numeric(18,4), total numeric(18,4),
    summary text, supplier_legacy_id int,
    order_qty numeric(18,4), pdraw_qty numeric(18,4),
    node_class smallint, mgoods_legacy_id int, mcolor_legacy_id int, ass_team_legacy_id int,
    parent_legacy_id int, dqty numeric(18,4), in_qty numeric(18,4),
    pwdraw_qty numeric(18,4), soc_item_legacy_id int, owdraw_qty numeric(18,4),
    lqty numeric(18,4), pqty numeric(18,4), slqty numeric(18,4), rqty numeric(18,4),
    lstatus smallint, mqty numeric(18,4),
    eo_qty numeric(18,4), ei_qty numeric(18,4), ew_qty numeric(18,4),
    level smallint, pa_qty numeric(18,4),
    source_doc_no text);
\copy cost_stage FROM '/tmp/production_plan_costs.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- F_DateReport / F_DateReportItem 0 行：仅 staging + \copy（验证 CSV 形态对齐），
--   INSERT 跳过（见末尾注释）。保留 staging 以便未来老库启用时直接复用映射规则。
CREATE TEMP TABLE dr_stage (
    legacy_id int, bill_no text, bill_date date, warehouse_legacy_id int,
    worker_legacy_id int, maker_legacy int, approver_legacy int, remark text,
    status smallint, supplier_legacy_id int, cancel_bit boolean, workshop_legacy_id int);
\copy dr_stage FROM '/tmp/production_daily_reports.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE dri_stage (
    legacy_id int, report_legacy_id int, goods_legacy_id int, color_legacy_id int,
    qty numeric(18,4), remark text, sales_order_no text, plan_no text,
    sales_order_item_legacy int, plan_item_legacy_id int,
    price numeric(18,4), total numeric(18,4), client_name text,
    unit_legacy_id int, unit_rate numeric(18,6),
    boxes numeric(18,4), per_box_qty numeric(18,4), stotal numeric(18,4), weight numeric(18,4),
    order_date date, order_qty numeric(18,4), outbound_qty numeric(18,4),
    outbound_no text, step_legacy_id int);
\copy dri_stage FROM '/tmp/production_daily_report_items.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)


-- ======================== 2. 自动补录缺失基础资料（同采购范式） ========================
-- 老库 BOM 可能引用已删货品/颜色/单位/供应商；引用完整性优先，最小存根补录。
BEGIN;
SELECT set_config('app.business_identifier_legacy_import', 'on', true);

-- 货品历史 FK 锚：legacy_id+name+auto_created=TRUE；不是待补全普通货品，V177/V181 要求选择器/BOM/MRP 隔离。
WITH candidates AS (
    SELECT DISTINCT lid
    FROM (SELECT goods_legacy_id AS lid FROM item_stage WHERE goods_legacy_id IS NOT NULL AND goods_legacy_id <> 0 UNION ALL
          SELECT mgoods_legacy_id FROM item_stage WHERE mgoods_legacy_id IS NOT NULL AND mgoods_legacy_id <> 0 UNION ALL
          SELECT goods_legacy_id FROM cost_stage WHERE goods_legacy_id IS NOT NULL AND goods_legacy_id <> 0 UNION ALL
          SELECT mgoods_legacy_id FROM cost_stage WHERE mgoods_legacy_id IS NOT NULL AND mgoods_legacy_id <> 0) t
    WHERE NOT EXISTS (SELECT 1 FROM goods g WHERE g.legacy_id = lid)
), numbered AS (
    SELECT candidates.*, row_number() OVER (ORDER BY lid) AS seq_ordinal,
           count(*) OVER ()::bigint AS allocation_count
    FROM candidates
), reserved AS (
    INSERT INTO category_master_code_sequences (master_type, last_seq)
    SELECT 'GOODS', COALESCE(max(allocation_count), 0) FROM numbered
    ON CONFLICT (master_type) DO UPDATE
    SET last_seq = category_master_code_sequences.last_seq + EXCLUDED.last_seq
    RETURNING last_seq
)
INSERT INTO goods (legacy_id, code, name, auto_created, code_managed, code_sequence)
SELECT lid, 'LEGACY-G-' || lid, '（迁移自动补录 legacy ' || lid || '）', TRUE, FALSE,
       reserved.last_seq - numbered.allocation_count + numbered.seq_ordinal
FROM numbered CROSS JOIN reserved
ON CONFLICT (legacy_id) DO UPDATE
SET code = COALESCE(goods.code, EXCLUDED.code);

-- 颜色（0 = 无色，不补）
INSERT INTO colors (legacy_id, code, name, status)
SELECT DISTINCT lid, 'LEGACY-C-' || lid, '（迁移自动补录）', '使用'
FROM (SELECT color_legacy_id AS lid FROM item_stage WHERE color_legacy_id IS NOT NULL AND color_legacy_id <> 0 UNION ALL
      SELECT color_legacy_id FROM cost_stage WHERE color_legacy_id IS NOT NULL AND color_legacy_id <> 0 UNION ALL
      SELECT mcolor_legacy_id FROM cost_stage WHERE mcolor_legacy_id IS NOT NULL AND mcolor_legacy_id <> 0) t
WHERE NOT EXISTS (SELECT 1 FROM colors c WHERE c.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- 单位（从计划明细反推）
INSERT INTO units (legacy_id, code, name, status)
SELECT DISTINCT lid, 'LEGACY-U-' || lid, '（迁移自动补录）', '使用'
FROM (SELECT unit_legacy_id AS lid FROM item_stage WHERE unit_legacy_id IS NOT NULL AND unit_legacy_id <> 0) t
WHERE NOT EXISTS (SELECT 1 FROM units u WHERE u.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- 供应商（从 BOM 建议供应反推）
WITH candidates AS (
    SELECT DISTINCT lid
    FROM (SELECT supplier_legacy_id AS lid FROM cost_stage
          WHERE supplier_legacy_id IS NOT NULL AND supplier_legacy_id <> 0) t
    WHERE NOT EXISTS (SELECT 1 FROM suppliers s WHERE s.legacy_id = lid)
), numbered AS (
    SELECT candidates.*, row_number() OVER (ORDER BY lid) AS seq_ordinal,
           count(*) OVER ()::bigint AS allocation_count
    FROM candidates
), reserved AS (
    INSERT INTO category_master_code_sequences (master_type, last_seq)
    SELECT 'SUPPLIER', COALESCE(max(allocation_count), 0) FROM numbered
    ON CONFLICT (master_type) DO UPDATE
    SET last_seq = category_master_code_sequences.last_seq + EXCLUDED.last_seq
    RETURNING last_seq
)
INSERT INTO suppliers (legacy_id, category_id, code, name, status, code_managed, code_sequence)
SELECT lid, (SELECT id FROM supplier_categories WHERE legacy_id = -1),
       'LEGACY-S-' || lid, '（迁移自动补录）', '使用', FALSE,
       reserved.last_seq - numbered.allocation_count + numbered.seq_ordinal
FROM numbered CROSS JOIN reserved
ON CONFLICT (legacy_id) DO UPDATE
SET category_id = COALESCE(suppliers.category_id, EXCLUDED.category_id);

COMMIT;


-- ======================== 3. production_plans ========================
-- department_id 留 NULL：WorkShop varchar(250) 装数字/名字（样本 "37"/"38"），
--   无 departments legacy_id 对齐，后续建 workshop_legacy_map 表回填。
-- maker_id/approver_id 留 NULL（同采购）：B_Worker 与 employees 无对齐。
-- maker_name/approver_name：冻结老库 Sys_Operator.fname / B_Worker.Emp_Name
--   （export 端双表 COALESCE 取名）。报表 COALESCE(em.full_name, maker_name)
--   —— employees.legacy_id 对齐后用真名，否则用冻结名（同委外 V66 范式）。
BEGIN;
SELECT set_config('app.business_identifier_legacy_import', 'on', true);
INSERT INTO production_plans (
    legacy_id, bill_no, bill_date, f_style, delivery_date,
    workshop_name, worker_name, seller_name,
    maker_legacy_id, approver_legacy_id, maker_name, approver_name,
    remark, status, is_closed, is_stopped, is_canceled,
    source_daily_report_id)
SELECT s.legacy_id, s.bill_no, s.bill_date, NULLIF(s.f_style,''), s.delivery_date,
       NULLIF(s.workshop_name,''), NULLIF(s.worker_name,''), NULLIF(s.seller_name,''),
       s.maker_legacy, s.approver_legacy, NULLIF(s.maker_name,''), NULLIF(s.approver_name,''),
       NULLIF(s.remark,''), s.status,
       COALESCE(s.fulfill_bit, FALSE), COALESCE(s.stop_bit, FALSE), COALESCE(s.cancel_bit, FALSE),
       NULL::uuid  -- 历史计划没有可证明的报工来源 UUID，禁止按自由文本猜测
FROM plan_stage s;
COMMIT;


-- ======================== 4. production_plan_items ========================
-- sales_order_item_id 子查询映射（V51 sales_order_items 必须先迁）；老库样本
--   S_OrderID 多为 0（直接计划生产），JOIN 率预期较低，无 FK 强约束。
-- bill_date/bill_no 反冗余自 plan_stage（裁剪索引 + 报表免 JOIN 主表）。
BEGIN;
SELECT set_config('app.business_identifier_legacy_import', 'on', true);
INSERT INTO production_plan_items (
    legacy_id, bill_no, bill_date, plan_id, line_no, product_no,
    goods_id, color_id, mgoods_id, unit_id, unit_rate,
    sales_order_item_id, sales_order_no, client_name, client_no,
    oqty, qty, lqty, iqty, fqty, rqty, bqty, tqty, paqty, isrqty, cpqty, poqty, piqty,
    order_date, outbound_date, plan_begin_date, plan_end_date,
    finished_weight, inbound_weight, lstatus, cstatus,
    step_legacy_id, veil_legacy_id, ass_team_legacy_id, fittings,
    request_note, customer_model, discount, label_no, plan_app_no,
    source_doc_no, remark)
SELECT s.legacy_id, p.bill_no, p.bill_date,
       (SELECT id FROM production_plans WHERE legacy_id = s.plan_legacy_id),
       ROW_NUMBER() OVER (PARTITION BY s.plan_legacy_id ORDER BY s.legacy_id),
       s.product_no,
       (SELECT id FROM goods  WHERE legacy_id = s.goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy_id AND s.color_legacy_id <> 0),
       (SELECT id FROM goods  WHERE legacy_id = s.mgoods_legacy_id AND s.mgoods_legacy_id <> 0),
       (SELECT id FROM units  WHERE legacy_id = s.unit_legacy_id),
       COALESCE(s.unit_rate, 1),
       (SELECT id FROM sales_order_items WHERE legacy_id = s.s_order_item_legacy AND s.s_order_item_legacy <> 0),
       NULLIF(s.sales_order_no,''), NULLIF(s.client_name,''), NULLIF(s.client_no,''),
       COALESCE(s.oqty,0), COALESCE(s.qty,0), COALESCE(s.lqty,0), COALESCE(s.iqty,0),
       COALESCE(s.fqty,0), COALESCE(s.rqty,0), COALESCE(s.bqty,0), COALESCE(s.tqty,0),
       COALESCE(s.paqty,0), COALESCE(s.isrqty,0), COALESCE(s.cpqty,0),
       COALESCE(s.poqty,0), COALESCE(s.piqty,0),
       s.order_date, s.outbound_date, s.plan_begin_date, s.plan_end_date,
       s.finished_weight, s.inbound_weight, s.lstatus, s.cstatus,
       s.step_legacy_id, s.veil_legacy_id, s.ass_team_legacy_id, NULLIF(s.fittings,''),
       NULLIF(s.request_note,''), NULLIF(s.customer_model,''), s.discount,
       NULLIF(s.label_no,''), NULLIF(s.plan_app_no,''),
       CONCAT_WS(' | ',
                  CASE WHEN NULLIF(s.in_no,'')   IS NULL THEN NULL ELSE 'IN:'  || s.in_no  END,
                  CASE WHEN NULLIF(s.tran_no,'') IS NULL THEN NULL ELSE 'TRAN:' || s.tran_no END),
       NULLIF(s.remark,'')
FROM item_stage s JOIN plan_stage p ON p.legacy_id = s.plan_legacy_id;
COMMIT;


-- ======================== 5. production_plan_costs（1.36M 行 · 按年分批 INSERT） ========================
-- ⭐ 反冗余 bill_date / bill_no 经 cost_stage -> item_stage -> plan_stage 三级链取
--   （BillID -> F_PlanItem.ID -> F_PlanItem.BillID -> F_Plan.BillDate）。
-- ⚠ BillID 指向 F_PlanItem.ID（不是 F_Plan.ID！），bill_item_id 经
--   production_plan_items.legacy_id 子查询映射为新 UUID。
-- 链断裂行（BillID 在 item_stage 找不到，或 item_stage.plan_legacy_id 在 plan_stage 找不到）：
--   bill_date 用 '1970-01-01' 兜底，落入 DEFAULT 分区，校验段报告此类异常行数。
--
-- 分批策略：先一次性物化 cost_prepared TEMP TABLE（含所有 FK UUID 解析 + 兜底 bill_date），
--   再用 PROCEDURE 循环 13 个年度（2018-2030）+ 1 个 outlier 批，每年独立 COMMIT
--   （PG 11+ PROCEDURE 允许循环内 COMMIT，DO 块不允许）。
--   单批 ~100k 行级，失败可单独重跑（NOT EXISTS 防重）。

-- 5a. 物化解析好的 cost_prepared（hash JOIN 一次性算完，避免 1.36M 次相关子查询）
--     注：bill_item_id 来自 production_plan_items.legacy_id JOIN。若 BillID 找不到对应
--     plan_item（孤儿），bill_item_id 为 NULL，因 V55 NOT NULL 约束无法 INSERT -> 在
--     5b 的 INSERT 中过滤掉，校验段报告 "orphan BillID dropped" 计数。
--     p.bill_date / p.bill_no NULL（链断裂在 F_PlanItem -> F_Plan 那段）时，bill_date
--     用 '1970-01-01' 兜底（落入 DEFAULT 分区），bill_no 用 'LEGACY-ORPHAN-COST-<id>'
--     兜底，均不影响 INSERT 成功（bill_item_id 仍非空）。
CREATE TEMP TABLE cost_prepared AS
SELECT s.legacy_id,
       pi.id  AS bill_item_id,
       COALESCE(p.bill_no, 'LEGACY-ORPHAN-COST-' || s.legacy_id) AS bill_no,
       COALESCE(p.bill_date, '1970-01-01'::date)                 AS bill_date,
       s.parent_legacy_id, s.level, s.node_class,
       g.id  AS goods_id,
       c.id  AS color_id,
       mg.id AS master_goods_id,
       mc.id AS master_color_id,
       soci.id AS sales_order_cost_item_id,
       s.qty, s.dqty, s.pqty, s.lqty, s.slqty, s.rqty,
       s.order_qty, s.in_qty, s.pdraw_qty, s.owdraw_qty, s.pwdraw_qty,
       s.eo_qty, s.ei_qty, s.ew_qty, s.mqty, s.pa_qty,
       s.price, s.total,
       sup.id AS supplier_id,
       s.ass_team_legacy_id,
       NULLIF(s.source_doc_no,'') AS source_doc_no,
       s.lstatus,
       NULLIF(s.summary,'')       AS summary
FROM cost_stage s
LEFT JOIN item_stage             i    ON i.legacy_id    = s.bill_item_legacy_id
LEFT JOIN plan_stage             p    ON p.legacy_id    = i.plan_legacy_id
LEFT JOIN production_plan_items  pi   ON pi.legacy_id   = s.bill_item_legacy_id
LEFT JOIN goods                  g    ON g.legacy_id    = s.goods_legacy_id
LEFT JOIN colors                 c    ON c.legacy_id    = s.color_legacy_id  AND s.color_legacy_id  <> 0
LEFT JOIN goods                  mg   ON mg.legacy_id   = s.mgoods_legacy_id AND s.mgoods_legacy_id <> 0
LEFT JOIN colors                 mc   ON mc.legacy_id   = s.mcolor_legacy_id AND s.mcolor_legacy_id <> 0
LEFT JOIN sales_order_cost_items soci ON soci.legacy_id = s.soc_item_legacy_id AND s.soc_item_legacy_id <> 0
LEFT JOIN suppliers              sup  ON sup.legacy_id  = s.supplier_legacy_id AND s.supplier_legacy_id <> 0;

CREATE INDEX idx_cost_prepared_date ON cost_prepared (bill_date);
CREATE INDEX idx_cost_prepared_orphan ON cost_prepared ((bill_item_id IS NULL));
ANALYZE cost_prepared;

-- 5b. 按年分批 INSERT（PROCEDURE 内 COMMIT，单批失败可重跑）
CREATE OR REPLACE PROCEDURE migrate_plan_costs_yearly() LANGUAGE plpgsql AS $$
DECLARE
    y int;
    n int;
BEGIN
    -- 正常年份 2018-2030（覆盖老库历史 + 设计 §5 已建分区）
    FOR y IN 2018..2030 LOOP
        INSERT INTO production_plan_costs (
            legacy_id, bill_item_id, bill_no, bill_date,
            parent_legacy_id, level, node_class,
            goods_id, color_id, master_goods_id, master_color_id, sales_order_cost_item_id,
            qty, dqty, pqty, lqty, slqty, rqty, order_qty, in_qty,
            pdraw_qty, owdraw_qty, pwdraw_qty, eo_qty, ei_qty, ew_qty, mqty, pa_qty,
            price, total, supplier_id, ass_team_legacy_id,
            source_doc_no, lstatus, summary)
        SELECT legacy_id, bill_item_id, bill_no, bill_date,
               parent_legacy_id, level, node_class,
               goods_id, color_id, master_goods_id, master_color_id, sales_order_cost_item_id,
               qty, dqty, pqty, lqty, slqty, rqty, order_qty, in_qty,
               pdraw_qty, owdraw_qty, pwdraw_qty, eo_qty, ei_qty, ew_qty, mqty, pa_qty,
               price, total, supplier_id, ass_team_legacy_id,
               source_doc_no, lstatus, summary
        FROM cost_prepared
        WHERE bill_item_id IS NOT NULL                            -- ⚠ 过滤孤儿 BillID（NOT NULL 约束）
          AND EXTRACT(YEAR FROM bill_date) = y
          AND NOT EXISTS (SELECT 1 FROM production_plan_costs pc WHERE pc.legacy_id = cost_prepared.legacy_id);
        GET DIAGNOSTICS n = ROW_COUNT;
        RAISE NOTICE 'Year %: inserted % rows', y, n;
        COMMIT;
    END LOOP;

    -- outlier 批：1970 兜底行 + 真实异常日期（<2018 / >2030），全进 DEFAULT 分区
    INSERT INTO production_plan_costs (
        legacy_id, bill_item_id, bill_no, bill_date,
        parent_legacy_id, level, node_class,
        goods_id, color_id, master_goods_id, master_color_id, sales_order_cost_item_id,
        qty, dqty, pqty, lqty, slqty, rqty, order_qty, in_qty,
        pdraw_qty, owdraw_qty, pwdraw_qty, eo_qty, ei_qty, ew_qty, mqty, pa_qty,
        price, total, supplier_id, ass_team_legacy_id,
        source_doc_no, lstatus, summary)
    SELECT legacy_id, bill_item_id, bill_no, bill_date,
           parent_legacy_id, level, node_class,
           goods_id, color_id, master_goods_id, master_color_id, sales_order_cost_item_id,
           qty, dqty, pqty, lqty, slqty, rqty, order_qty, in_qty,
           pdraw_qty, owdraw_qty, pwdraw_qty, eo_qty, ei_qty, ew_qty, mqty, pa_qty,
           price, total, supplier_id, ass_team_legacy_id,
           source_doc_no, lstatus, summary
    FROM cost_prepared
    WHERE bill_item_id IS NOT NULL                            -- ⚠ 过滤孤儿 BillID（NOT NULL 约束）
      AND EXTRACT(YEAR FROM bill_date) NOT BETWEEN 2018 AND 2030
      AND NOT EXISTS (SELECT 1 FROM production_plan_costs pc WHERE pc.legacy_id = cost_prepared.legacy_id);
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'Outlier year (<2018 or >2030, incl. 1970 fallback): inserted % rows', n;
    COMMIT;
END $$;

CALL migrate_plan_costs_yearly();
DROP PROCEDURE migrate_plan_costs_yearly();


-- ======================== 6. parent_id 自引用回填 ========================
-- parent_legacy_id -> 新 UUID（同年同分区；父子 bill_date 必一致，设计不变式）。
--   顶层行 parent_legacy_id = 0 不回填（保持 NULL）。
--   查不到父行（父 legacy 不在结果集）也保持 NULL，校验段报告。
-- 分区表 PK = (id, bill_date)，无法建 FK 自引用，靠此 UPDATE + 索引 + 应用层保证。
BEGIN;
UPDATE production_plan_costs c SET parent_id = p.id
FROM production_plan_costs p
WHERE c.parent_legacy_id <> 0
  AND p.legacy_id = c.parent_legacy_id
  AND p.bill_date = c.bill_date;
COMMIT;


-- ======================== 7. production_daily_reports(+items)：0 行跳过 INSERT ========================
-- F_DateReport / F_DateReportItem 在 YTDQ_2023 为 0 行（design 24 §3.4，字段类型
--   自相矛盾从未启用）。staging 已 \copy 验证形态；INSERT 跳过，结构留位。
-- 未来老库启用时，按 design 24 §7.4 映射规则补：
--   * daily_reports: warehouse_id 经 warehouses.legacy_id 映射 StockID；
--     department_id 留 NULL + workshop_name 留底（WorkShop int 与 F_Plan varchar 矛盾，
--     design §7.4 统一为 department_id + workshop_name 文本占位）；
--     VendID -> supplier_id；MakerID/ApproverID/WorkerID 留 NULL + *_legacy_id 留底。
--   * daily_report_items: plan_item_id 经 production_plan_items.legacy_id 映射 PlanID；
--     sales_order_item_id 经 sales_order_items.legacy_id 映射 OrderID；
--     goods/color/unit 经主档 legacy_id 映射。


-- ======================== 8. 校验 ========================
SELECT '!! 计划单头（应 = 7235）        ' || (SELECT count(*) FROM production_plans) AS r
UNION ALL SELECT '!! 计划明细（应 = 73388）       ' || (SELECT count(*) FROM production_plan_items)
UNION ALL SELECT '!! BOM 展开（应 = 1359875）     ' || (SELECT count(*) FROM production_plan_costs)
UNION ALL SELECT '   legacy_id 覆盖（cost）       ' || (SELECT count(*) FROM production_plan_costs WHERE legacy_id IS NOT NULL)
UNION ALL SELECT '   bill_date 覆盖（cost NOT NULL） ' || (SELECT count(*) FROM production_plan_costs WHERE bill_date IS NOT NULL)
UNION ALL SELECT '   bill_date 1970 兜底行（链断裂） ' || (SELECT count(*) FROM production_plan_costs WHERE bill_date = '1970-01-01')
UNION ALL SELECT '   bill_item_id 挂接（NOT NULL）  ' || (SELECT count(*) FROM production_plan_costs WHERE bill_item_id IS NOT NULL)
UNION ALL SELECT '   orphan BillID dropped（NOT NULL 约束） ' || (SELECT count(*) FROM cost_prepared WHERE bill_item_id IS NULL)
UNION ALL SELECT '   BOM 顶层（parent_legacy_id=0） ' || (SELECT count(*) FROM production_plan_costs WHERE parent_legacy_id = 0)
UNION ALL SELECT '   BOM 父子挂接（parent_id 非空） ' || (SELECT count(*) FROM production_plan_costs WHERE parent_id IS NOT NULL)
UNION ALL SELECT '   BOM 父子未挂上（legacy!=0 且 parent_id NULL） ' ||
        (SELECT count(*) FROM production_plan_costs WHERE parent_legacy_id <> 0 AND parent_id IS NULL)
UNION ALL SELECT '   goods_id NULL（应 0，已自动补录） ' || (SELECT count(*) FROM production_plan_costs WHERE goods_id IS NULL)
UNION ALL SELECT '   计划明细挂销售订单（V51 JOIN 率） ' || (SELECT count(*) FROM production_plan_items WHERE sales_order_item_id IS NOT NULL)
UNION ALL SELECT '   BOM 挂销售成本（SOCItemID JOIN） ' || (SELECT count(*) FROM production_plan_costs WHERE sales_order_cost_item_id IS NOT NULL)
UNION ALL SELECT '   货品历史引用锚（全库）         ' || (SELECT count(*) FROM goods WHERE auto_created = TRUE)
UNION ALL SELECT '   补录颜色                      ' || (SELECT count(*) FROM colors WHERE name = '（迁移自动补录）')
UNION ALL SELECT '   补录单位                      ' || (SELECT count(*) FROM units  WHERE name = '（迁移自动补录）')
UNION ALL SELECT '   补录供应商                    ' || (SELECT count(*) FROM suppliers WHERE name = '（迁移自动补录）');

-- 分区分布（预期集中在 2022-2026；1970 = 链断裂兜底；其余年份 0）
SELECT EXTRACT(YEAR FROM bill_date)::int AS yr, count(*) AS cnt
FROM production_plan_costs
GROUP BY 1
ORDER BY 1;

-- 制单员/审核员冻结名命中（export 端 JOIN Sys_Operator/B_Worker 取名）
SELECT '!! 计划单头（应 = 7235）        ' || (SELECT count(*) FROM production_plans) AS r
UNION ALL SELECT '   maker_name 命中（冻结名）   ' || (SELECT count(*) FROM production_plans WHERE maker_name IS NOT NULL)
UNION ALL SELECT '   approver_name 命中（冻结名） ' || (SELECT count(*) FROM production_plans WHERE approver_name IS NOT NULL);


-- ======================== 9. 刷新生产报表物化视图 ========================
-- 迁完必须刷新，否则 production_monthly_mv 为空 → 月度/汇总报表无数据
-- （销售 migrate 踩过的坑，见 MEMORY「sales-report-completion」）。
-- refresh_production_monthly_mv() 用 CONCURRENTLY（V56 已建唯一索引
-- mv_production_monthly_uidx），须在所有 COMMIT 之后单语句调用（不在事务块内）。
SELECT refresh_production_monthly_mv();
