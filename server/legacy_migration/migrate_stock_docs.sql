-- =====================================================================
-- 仓库管理 9 单据迁移：老库 O_* → stock_documents + stock_document_items（统一表）
-- + StockGoods 台账 → stock_balances（余额）+ stock_movements（流水，供报表）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --stock-docs
-- 前提：V42-V49 已建表；goods/colors/units/suppliers/clients/warehouses 主档已迁。
-- 源 CSV（export_legacy.ps1 WarehouseDocs 产出）：
--   stock_{transfer,other_in,other_out,draw,wdraw,finished_in,finished_out,check}_m.csv（主）
--   stock_{...}_i.csv（明细）  +  stock_goods.csv（StockGoods 台账）
--
-- 【幂等 · 可重跑】（用户要求：未来新数据直接重跑即迁入）
--   开头清三处：stock_movements 的 STOCK_DOC 源、stock_document_items、stock_documents、
--   stock_balances（全清后从 StockGoods 重建）。重跑安全。
--   缺失基础资料（goods/units/colors/warehouses）自动补录（§自动补录）。
--
-- 【结构】统一 staging：主表/明细各一张 TEMP 表 + doc_type 列，一次性 \copy 全部 8 类
--   （accumulate，不清空）→ 自动补录（此时 staging 满）→ 各一条 INSERT（doc_type 来自
--   staging，JOIN 用 (legacy_id, doc_type) 消歧，因各 O_ 表 IDENTITY 独立、ID 跨表会重复）。
--   比"每类一段"更 DRY：8 段 INSERT → 2 段。复制本文件改 doc 集合即迁移新单据类型。
--
-- 【人员字段】worker/maker/approver：保留 *_legacy_id INT（worker 源随类型不同：DRAW=GetID 领料人、
--   WDRAW=ReturnID 退料人、CHECK=CheckID 盘点人/跟单员、其余=WorkerID 经办/跟单）；ass_team=装配班组(DRAW)。
--   并自动补录 B_Worker→employees stub（legacy_id 融合键），报表 LEFT JOIN employees 出人名；HR 真名单不覆盖。
-- 【状态】老库历史只有 1（已审）/ -1（红冲），无草稿；照搬。
-- 【doc_type】TRANSFER/OTHER_IN/OTHER_OUT/DRAW/WDRAW/FINISHED_IN/FINISHED_OUT/CHECK
--   （WASTE 损耗老库 O_Waste 0 行，跳过；结构/枚举已留位。）
-- =====================================================================

BEGIN;
SET session_replication_role = replica;
-- 清旧（幂等）：仓库源流水 + 统一单据 + 余额（余额从 StockGoods 全量重建）
DELETE FROM stock_movements WHERE source_doc_type = 'STOCK_DOC';
TRUNCATE stock_document_items, stock_documents, stock_balances;
SET session_replication_role = DEFAULT;

-- ======================== staging（统一形状 + doc_type） ========================
CREATE TEMP TABLE doc_stage (
    legacy_id int, bill_no text, bill_date date,
    stock_legacy_id int, to_stock_legacy_id int,
    client_legacy_id int, supplier_legacy_id int,
    worker_legacy int, maker_legacy int, approver_legacy int,
    plan_no text, bill_type text, remark text,
    total_original numeric(18,4), status smallint, cancel_bit boolean,
    ass_team text,
    doc_type text);

CREATE TEMP TABLE item_stage (
    legacy_id int, bill_legacy_id int, goods_legacy_id int, color_legacy_id int,
    qty numeric(18,4), price numeric(18,4), amount numeric(18,4),
    unit_legacy_id int, unit_rate numeric(18,6), weight numeric(18,4),
    surplus_qty numeric(18,4), count_qty numeric(18,4),
    place_legacy_id int, upstream_legacy_id int,
    source_doc_no text, summary text,
    doc_type text);

CREATE TEMP TABLE sg_stage (
    stock_legacy int, goods_legacy int, color_legacy int, year int,
    qty numeric(18,4), fact_qty numeric(18,4), total numeric(18,2));

-- ======================== 载入全部 8 类主表（accumulate，标 doc_type） ========================
\copy doc_stage(legacy_id,bill_no,bill_date,stock_legacy_id,to_stock_legacy_id,client_legacy_id,supplier_legacy_id,worker_legacy,maker_legacy,approver_legacy,plan_no,bill_type,remark,total_original,status,cancel_bit,ass_team) FROM '/tmp/stock_transfer_m.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE doc_stage SET doc_type='TRANSFER' WHERE doc_type IS NULL;
\copy doc_stage(legacy_id,bill_no,bill_date,stock_legacy_id,to_stock_legacy_id,client_legacy_id,supplier_legacy_id,worker_legacy,maker_legacy,approver_legacy,plan_no,bill_type,remark,total_original,status,cancel_bit,ass_team) FROM '/tmp/stock_other_in_m.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE doc_stage SET doc_type='OTHER_IN' WHERE doc_type IS NULL;
\copy doc_stage(legacy_id,bill_no,bill_date,stock_legacy_id,to_stock_legacy_id,client_legacy_id,supplier_legacy_id,worker_legacy,maker_legacy,approver_legacy,plan_no,bill_type,remark,total_original,status,cancel_bit,ass_team) FROM '/tmp/stock_other_out_m.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE doc_stage SET doc_type='OTHER_OUT' WHERE doc_type IS NULL;
\copy doc_stage(legacy_id,bill_no,bill_date,stock_legacy_id,to_stock_legacy_id,client_legacy_id,supplier_legacy_id,worker_legacy,maker_legacy,approver_legacy,plan_no,bill_type,remark,total_original,status,cancel_bit,ass_team) FROM '/tmp/stock_draw_m.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE doc_stage SET doc_type='DRAW' WHERE doc_type IS NULL;
\copy doc_stage(legacy_id,bill_no,bill_date,stock_legacy_id,to_stock_legacy_id,client_legacy_id,supplier_legacy_id,worker_legacy,maker_legacy,approver_legacy,plan_no,bill_type,remark,total_original,status,cancel_bit,ass_team) FROM '/tmp/stock_wdraw_m.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE doc_stage SET doc_type='WDRAW' WHERE doc_type IS NULL;
\copy doc_stage(legacy_id,bill_no,bill_date,stock_legacy_id,to_stock_legacy_id,client_legacy_id,supplier_legacy_id,worker_legacy,maker_legacy,approver_legacy,plan_no,bill_type,remark,total_original,status,cancel_bit,ass_team) FROM '/tmp/stock_finished_in_m.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE doc_stage SET doc_type='FINISHED_IN' WHERE doc_type IS NULL;
\copy doc_stage(legacy_id,bill_no,bill_date,stock_legacy_id,to_stock_legacy_id,client_legacy_id,supplier_legacy_id,worker_legacy,maker_legacy,approver_legacy,plan_no,bill_type,remark,total_original,status,cancel_bit,ass_team) FROM '/tmp/stock_finished_out_m.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE doc_stage SET doc_type='FINISHED_OUT' WHERE doc_type IS NULL;
\copy doc_stage(legacy_id,bill_no,bill_date,stock_legacy_id,to_stock_legacy_id,client_legacy_id,supplier_legacy_id,worker_legacy,maker_legacy,approver_legacy,plan_no,bill_type,remark,total_original,status,cancel_bit,ass_team) FROM '/tmp/stock_check_m.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE doc_stage SET doc_type='CHECK' WHERE doc_type IS NULL;

-- ======================== 载入全部 8 类明细（accumulate，标 doc_type） ========================
\copy item_stage(legacy_id,bill_legacy_id,goods_legacy_id,color_legacy_id,qty,price,amount,unit_legacy_id,unit_rate,weight,surplus_qty,count_qty,place_legacy_id,upstream_legacy_id,source_doc_no,summary) FROM '/tmp/stock_transfer_i.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE item_stage SET doc_type='TRANSFER' WHERE doc_type IS NULL;
\copy item_stage(legacy_id,bill_legacy_id,goods_legacy_id,color_legacy_id,qty,price,amount,unit_legacy_id,unit_rate,weight,surplus_qty,count_qty,place_legacy_id,upstream_legacy_id,source_doc_no,summary) FROM '/tmp/stock_other_in_i.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE item_stage SET doc_type='OTHER_IN' WHERE doc_type IS NULL;
\copy item_stage(legacy_id,bill_legacy_id,goods_legacy_id,color_legacy_id,qty,price,amount,unit_legacy_id,unit_rate,weight,surplus_qty,count_qty,place_legacy_id,upstream_legacy_id,source_doc_no,summary) FROM '/tmp/stock_other_out_i.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE item_stage SET doc_type='OTHER_OUT' WHERE doc_type IS NULL;
\copy item_stage(legacy_id,bill_legacy_id,goods_legacy_id,color_legacy_id,qty,price,amount,unit_legacy_id,unit_rate,weight,surplus_qty,count_qty,place_legacy_id,upstream_legacy_id,source_doc_no,summary) FROM '/tmp/stock_draw_i.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE item_stage SET doc_type='DRAW' WHERE doc_type IS NULL;
\copy item_stage(legacy_id,bill_legacy_id,goods_legacy_id,color_legacy_id,qty,price,amount,unit_legacy_id,unit_rate,weight,surplus_qty,count_qty,place_legacy_id,upstream_legacy_id,source_doc_no,summary) FROM '/tmp/stock_wdraw_i.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE item_stage SET doc_type='WDRAW' WHERE doc_type IS NULL;
\copy item_stage(legacy_id,bill_legacy_id,goods_legacy_id,color_legacy_id,qty,price,amount,unit_legacy_id,unit_rate,weight,surplus_qty,count_qty,place_legacy_id,upstream_legacy_id,source_doc_no,summary) FROM '/tmp/stock_finished_in_i.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE item_stage SET doc_type='FINISHED_IN' WHERE doc_type IS NULL;
\copy item_stage(legacy_id,bill_legacy_id,goods_legacy_id,color_legacy_id,qty,price,amount,unit_legacy_id,unit_rate,weight,surplus_qty,count_qty,place_legacy_id,upstream_legacy_id,source_doc_no,summary) FROM '/tmp/stock_finished_out_i.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE item_stage SET doc_type='FINISHED_OUT' WHERE doc_type IS NULL;
\copy item_stage(legacy_id,bill_legacy_id,goods_legacy_id,color_legacy_id,qty,price,amount,unit_legacy_id,unit_rate,weight,surplus_qty,count_qty,place_legacy_id,upstream_legacy_id,source_doc_no,summary) FROM '/tmp/stock_check_i.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE item_stage SET doc_type='CHECK' WHERE doc_type IS NULL;

-- StockGoods 台账
\copy sg_stage FROM '/tmp/stock_goods.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

-- ======================== 自动补录缺失基础资料（此时 staging 满） ========================
-- 货品（盘点等可能引用已删货品；goods 无 NOT-NULL 无默认列，补最小存根：legacy_id+name）
INSERT INTO goods (legacy_id, name)
SELECT DISTINCT lid, '（迁移自动补录 legacy ' || lid || '）'
FROM (SELECT goods_legacy_id AS lid FROM item_stage
      WHERE goods_legacy_id IS NOT NULL AND goods_legacy_id <> 0) t
WHERE NOT EXISTS (SELECT 1 FROM goods g WHERE g.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- 单位（units 无 auto_created 列，用 code 前缀标识）
INSERT INTO units (legacy_id, code, name, status)
SELECT DISTINCT lid, 'LEGACY-U-' || lid, '（迁移自动补录）', '使用'
FROM (SELECT unit_legacy_id AS lid FROM item_stage
      WHERE unit_legacy_id IS NOT NULL AND unit_legacy_id <> 0) t
WHERE NOT EXISTS (SELECT 1 FROM units u WHERE u.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- 颜色（0=无色，不补）
INSERT INTO colors (legacy_id, code, name, status)
SELECT DISTINCT lid, 'LEGACY-C-' || lid, '（迁移自动补录）', '使用'
FROM (SELECT color_legacy_id AS lid FROM item_stage
      WHERE color_legacy_id IS NOT NULL AND color_legacy_id <> 0) t
WHERE NOT EXISTS (SELECT 1 FROM colors c WHERE c.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- 仓库（从主表 + 台账反推）
INSERT INTO warehouses (legacy_id, code, name, status, is_accountable, auto_created)
SELECT DISTINCT lid, 'LEGACY-W-' || lid, '（迁移自动补录）', '使用', TRUE, TRUE
FROM (SELECT stock_legacy_id AS lid FROM doc_stage UNION ALL
      SELECT to_stock_legacy_id FROM doc_stage UNION ALL
      SELECT stock_legacy FROM sg_stage) t
WHERE lid IS NOT NULL AND lid <> 0
  AND NOT EXISTS (SELECT 1 FROM warehouses w WHERE w.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- ======================== 人员补录：B_Worker → employees stub（融合键 legacy_id） ========================
-- 用户要求：老库有、新库没有就在员工表添加、显示名字（名字后带「（子类）」标记，sub_class 非空时）。
-- legacy_id = B_Worker.ID（融合键），full_name = Emp_Name，code='LEGACY-W-<id>'，
-- status='resigned'（老库很多人离职，默认离职；HR 以后在员工档案激活/补全真实信息），
-- department_id=DEPT_HR（HR 负责后续清理/分配真实部门），hire_date 占位，employment_type='regular'。
-- NOT EXISTS 守卫：用户已录真员工（同 legacy_id）优先，绝不覆盖；故重跑幂等、与真名单可融合。
-- sub_class 暂为 NULL（B_Worker 子类字段待 b_worker_columns.csv 确认后回填 SELECT）。
CREATE TEMP TABLE worker_stage (legacy_id int, name text, sub_class text);
\copy worker_stage FROM '/tmp/legacy_workers.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

INSERT INTO employees (legacy_id, code, full_name, id_type, department_id, hire_date, status, employment_type, legacy_category)
SELECT w.legacy_id, 'LEGACY-W-' || w.legacy_id, NULLIF(w.name,''), '其他',
       (SELECT id FROM departments WHERE code = 'DEPT_HR'), DATE '2000-01-01', 'resigned', 'regular',
       NULLIF(w.sub_class,'')
FROM worker_stage w
WHERE w.legacy_id IS NOT NULL AND w.legacy_id <> 0 AND NULLIF(w.name,'') IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM employees e WHERE e.legacy_id = w.legacy_id);

-- ======================== 统一单据头（一条 INSERT，全 8 类） ========================
INSERT INTO stock_documents (
    legacy_id, doc_type, bill_no, bill_date, warehouse_id, to_warehouse_id,
    supplier_id, client_id, plan_no, remark, total_original, total_local, status, is_closed,
    worker_legacy_id, maker_legacy_id, approver_legacy_id, ass_team)
SELECT s.legacy_id, s.doc_type, s.bill_no, s.bill_date,
       (SELECT id FROM warehouses WHERE legacy_id = s.stock_legacy_id),
       (SELECT id FROM warehouses WHERE legacy_id = s.to_stock_legacy_id AND s.to_stock_legacy_id <> 0),
       (SELECT id FROM suppliers  WHERE legacy_id = s.supplier_legacy_id AND s.supplier_legacy_id <> 0),
       (SELECT id FROM clients    WHERE legacy_id = s.client_legacy_id  AND s.client_legacy_id  <> 0),
       NULLIF(s.plan_no,''), NULLIF(s.remark,''),
       COALESCE(s.total_original,0), COALESCE(s.total_original,0), s.status, FALSE,
       NULLIF(s.worker_legacy,0), NULLIF(s.maker_legacy,0), NULLIF(s.approver_legacy,0), NULLIF(s.ass_team,'')
FROM doc_stage s;

-- ======================== 统一明细（一条 INSERT，全 8 类） ========================
-- upstream（退料→领料）暂留空，下一步 UPDATE 回填（INSERT 时新 id 尚未生成）。
INSERT INTO stock_document_items (
    legacy_id, doc_id, bill_type, bill_no, bill_date, line_no, goods_id, color_id, unit_id,
    unit_rate, qty, base_qty, price, amount_original, amount_local, weight, gift_qty,
    surplus_qty, count_qty, place, upstream_item_id, source_doc_no, remark)
SELECT s.legacy_id, d.id, s.doc_type, d.bill_no, d.bill_date,
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy_id, s.doc_type ORDER BY s.legacy_id),
       (SELECT id FROM goods  WHERE legacy_id = s.goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy_id),
       (SELECT id FROM units  WHERE legacy_id = s.unit_legacy_id),
       COALESCE(s.unit_rate,1), s.qty, ROUND(COALESCE(s.qty,0)*COALESCE(s.unit_rate,1),4),
       s.price, s.amount, s.amount, s.weight, 0,
       NULLIF(s.surplus_qty,0), NULLIF(s.count_qty,0),
       NULLIF(CAST(s.place_legacy_id AS TEXT),'0'),
       NULL,  -- upstream 回填见下
       NULLIF(s.source_doc_no,''), NULLIF(s.summary,'')
FROM item_stage s JOIN stock_documents d ON d.legacy_id = s.bill_legacy_id AND d.doc_type = s.doc_type;

-- 退料明细 → 领料明细 链路回填（upstream_legacy_id → DRAW 明细新 id）
UPDATE stock_document_items w SET upstream_item_id = i.id
FROM item_stage s, stock_document_items i
WHERE w.bill_type = 'WDRAW' AND w.legacy_id = s.legacy_id
  AND s.upstream_legacy_id IS NOT NULL AND s.upstream_legacy_id <> 0
  AND i.legacy_id = s.upstream_legacy_id AND i.bill_type = 'DRAW';

-- ======================== 重建库存余额（StockGoods → stock_balances） ========================
-- StockGoods 按「仓+货+色+年+库位」分行：QTY=年初余额(上年结转)、FactQTY=年末余额。
-- 当前余额 = 最新年(MAX year)的 FactQTY（同年多库位先 SUM，再取最新年；COALESCE 兜底 QTY）。
-- 旧实现误 SUM(所有年 QTY) → 跨年重复累加致库存虚高（货品54833: SUM=262204，实=最新年 FactQTY 182515）。
INSERT INTO stock_balances (warehouse_id, goods_id, color_id, qty, amount_local, last_movement_date)
SELECT warehouse_id, goods_id, color_id, fact_qty, total, now()
FROM (
    SELECT DISTINCT ON (warehouse_id, goods_id, color_id)
           warehouse_id, goods_id, color_id, fact_qty, total
    FROM (
        SELECT (SELECT id FROM warehouses WHERE legacy_id = g.stock_legacy) AS warehouse_id,
               (SELECT id FROM goods      WHERE legacy_id = g.goods_legacy) AS goods_id,
               (SELECT id FROM colors     WHERE legacy_id = g.color_legacy) AS color_id,
               g.year,
               SUM(COALESCE(g.fact_qty, g.qty)) AS fact_qty,
               SUM(g.total) AS total
        FROM sg_stage g
        GROUP BY 1, 2, 3, g.year
    ) yr
    WHERE warehouse_id IS NOT NULL AND goods_id IS NOT NULL
    ORDER BY warehouse_id, goods_id, color_id, yr.year DESC
) latest
WHERE fact_qty <> 0
ON CONFLICT (warehouse_id, goods_id, color_id) DO UPDATE
SET qty = EXCLUDED.qty, amount_local = EXCLUDED.amount_local, last_movement_date = now(), updated_at = now();

-- ======================== 回填仓库流水（已审单据 → stock_movements，供报表） ========================
INSERT INTO stock_movements (transaction_date, movement_type, source_doc_type, source_doc_id, source_item_id,
    goods_id, color_id, warehouse_id, direction, qty, unit_id, unit_rate, amount_local, remark)
SELECT d.bill_date::timestamptz,
       CASE d.doc_type WHEN 'OTHER_IN' THEN 11 WHEN 'OTHER_OUT' THEN 12
                       WHEN 'DRAW' THEN 5 WHEN 'WDRAW' THEN 6
                       WHEN 'FINISHED_IN' THEN 13 WHEN 'FINISHED_OUT' THEN 14 END,
       'STOCK_DOC', d.id, i.id, i.goods_id, i.color_id, d.warehouse_id,
       CASE WHEN d.doc_type IN ('OTHER_IN','WDRAW','FINISHED_IN') THEN 1 ELSE -1 END,
       i.base_qty, i.unit_id, i.unit_rate, i.amount_local, NULLIF(i.remark,'')
FROM stock_document_items i JOIN stock_documents d ON d.id = i.doc_id
WHERE d.status = 1 AND d.doc_type IN ('OTHER_IN','OTHER_OUT','DRAW','WDRAW','FINISHED_IN','FINISHED_OUT')
  AND i.goods_id IS NOT NULL AND d.warehouse_id IS NOT NULL;

-- 调拨：调出仓 -8 / 调入仓 +7（两条）
INSERT INTO stock_movements (transaction_date, movement_type, source_doc_type, source_doc_id, source_item_id,
    goods_id, color_id, warehouse_id, direction, qty, unit_id, unit_rate, remark)
SELECT d.bill_date::timestamptz, 8, 'STOCK_DOC', d.id, i.id, i.goods_id, i.color_id, d.warehouse_id,
       -1, i.base_qty, i.unit_id, i.unit_rate, '调拨出'
FROM stock_document_items i JOIN stock_documents d ON d.id = i.doc_id
WHERE d.status = 1 AND d.doc_type = 'TRANSFER' AND d.warehouse_id IS NOT NULL AND i.goods_id IS NOT NULL;

INSERT INTO stock_movements (transaction_date, movement_type, source_doc_type, source_doc_id, source_item_id,
    goods_id, color_id, warehouse_id, direction, qty, unit_id, unit_rate, remark)
SELECT d.bill_date::timestamptz, 7, 'STOCK_DOC', d.id, i.id, i.goods_id, i.color_id, d.to_warehouse_id,
       1, i.base_qty, i.unit_id, i.unit_rate, '调拨入'
FROM stock_document_items i JOIN stock_documents d ON d.id = i.doc_id
WHERE d.status = 1 AND d.doc_type = 'TRANSFER' AND d.to_warehouse_id IS NOT NULL AND i.goods_id IS NOT NULL;

-- 盘点：surplus>0 盘盈入 +9 / surplus<0 盘亏出 -10（按盘盈亏量，非全量）
INSERT INTO stock_movements (transaction_date, movement_type, source_doc_type, source_doc_id, source_item_id,
    goods_id, color_id, warehouse_id, direction, qty, unit_id, unit_rate, remark)
SELECT d.bill_date::timestamptz,
       CASE WHEN i.surplus_qty > 0 THEN 9 ELSE 10 END,
       'STOCK_DOC', d.id, i.id, i.goods_id, i.color_id, d.warehouse_id,
       CASE WHEN i.surplus_qty > 0 THEN 1 ELSE -1 END,
       ABS(i.surplus_qty), i.unit_id, i.unit_rate, NULLIF(i.remark,'')
FROM stock_document_items i JOIN stock_documents d ON d.id = i.doc_id
WHERE d.status = 1 AND d.doc_type = 'CHECK' AND i.surplus_qty IS NOT NULL AND i.surplus_qty <> 0
  AND i.goods_id IS NOT NULL AND d.warehouse_id IS NOT NULL;

COMMIT;

-- ======================== 刷新仓库月度物化视图（防汇总报表空，同 sales 修复） ========================
REFRESH MATERIALIZED VIEW stock_monthly_mv;

-- ======================== 校验 ========================
SELECT '✔ 主表合计 ' || (SELECT count(*) FROM stock_documents) || ' / 明细 ' || (SELECT count(*) FROM stock_document_items) AS r
UNION ALL SELECT '余额行 '   || (SELECT count(*) FROM stock_balances)
UNION ALL SELECT '仓库流水 ' || (SELECT count(*) FROM stock_movements WHERE source_doc_type='STOCK_DOC')
UNION ALL SELECT '补录货品 ' || (SELECT count(*) FROM goods WHERE name LIKE '（迁移自动补录%')
UNION ALL SELECT '补录员工 ' || (SELECT count(*) FROM employees WHERE code LIKE 'LEGACY-W-%')
UNION ALL SELECT '单据人员覆盖 ' || (SELECT count(*) FROM stock_documents WHERE worker_legacy_id IS NOT NULL OR maker_legacy_id IS NOT NULL OR approver_legacy_id IS NOT NULL)
UNION ALL SELECT '装配班组 ' || (SELECT count(*) FROM stock_documents WHERE ass_team IS NOT NULL)
UNION ALL SELECT '孤儿明细(无货品) ' || (SELECT count(*) FROM stock_document_items WHERE goods_id IS NULL)
UNION ALL SELECT '孤儿明细(无主表) ' || (SELECT count(*) FROM stock_document_items i WHERE NOT EXISTS (SELECT 1 FROM stock_documents d WHERE d.id=i.doc_id))
UNION ALL SELECT '退料挂领料 ' || (SELECT count(*) FROM stock_document_items WHERE bill_type='WDRAW' AND upstream_item_id IS NOT NULL);
