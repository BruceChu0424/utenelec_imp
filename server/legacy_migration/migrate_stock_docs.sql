-- =====================================================================
-- 仓库管理 9 单据迁移：老库 O_* → stock_documents + stock_document_items（统一表）
-- + StockGoods 台账 → stock_balances（余额）+ stock_movements（流水，供报表）
-- =====================================================================
-- 用法：bash server/legacy_migration/migrate.sh --stock-docs
-- 前提：Flyway 已应用至 V182；goods/colors/units/suppliers/clients/warehouses 主档已迁。
-- 源 CSV（export_legacy.ps1 WarehouseDocs 产出）：
--   stock_{transfer,other_in,other_out,draw,wdraw,finished_in,finished_out,check}_m.csv（主）
--   stock_{...}_i.csv（明细）  +  stock_goods.csv（StockGoods 台账）
--
-- 【受控重载】
--   开头清三处：stock_movements 的 STOCK_DOC 源、stock_document_items、stock_documents、
--   stock_balances（全清后从 StockGoods 重建）。任何下游生产/财务引用
--   都会由 FK 在导入前拒绝，绝不绕过触发器或级联删除。
--   缺失基础资料(goods/units/colors)自动补录(§自动补录)。仓库不补录(ADR-145)：
--   仓库一律经审过的 warehouse_crosswalk.csv 解析——
--     KEEP/MERGE 落到目标子仓；SPLIT(老库主仓 132)单据头记主仓 001，明细、流水、余额按
--     货品所属子仓(goods.owning_warehouse_id，须是可选良品子仓)拆分，所属仓为空的不迁；
--     可选兜底：会话设置 uten.legacy_unassigned_warehouse_code=<子仓编号>(migrate.sh 环境变量
--     UTEN_LEGACY_UNASSIGNED_WAREHOUSE_CODE)时落到该子仓；
--     DROP(老库已删除仓)的单据与余额不迁。
--   不迁的单据/明细/余额逐条记进 bootstrap_warehouse_exclusions(全量导入对账按它扣减并写入
--   运行记录，migrate.sh 导出成 data/import_report/warehouse_exclusions.csv)。
--
-- 【结构】统一 staging：主表/明细各一张 TEMP 表 + doc_type 列，一次性 \copy 全部 8 类
--   （accumulate，不清空）→ 自动补录（此时 staging 满）→ 各一条 INSERT（doc_type 来自
--   staging，JOIN 用 (legacy_id, doc_type) 消歧，因各 O_ 表 IDENTITY 独立、ID 跨表会重复）。
--   比"每类一段"更 DRY：8 段 INSERT → 2 段。复制本文件改 doc 集合即迁移新单据类型。
--
-- 【人员字段】三类整数不在同一命名空间：worker_legacy_id→B_Worker.ID（worker 源随类型不同：DRAW=GetID 领料人、
--   WDRAW=ReturnID 退料人、CHECK=CheckID 盘点人/跟单员、其余=WorkerID 经办/跟单）；ass_team=装配班组(DRAW)。
--   worker 同时写 employees UUID；maker_legacy_id/approver_legacy_id→Sys_Operator.ID，只按该表 ID
--   写 maker_name_snapshot/approver_name_snapshot，绝不拿 operator ID 匹配 employees.legacy_id。
--   B_Worker→employees stub 使用 legacy_id 融合键，HR 真名单不覆盖。
-- 【状态】老库历史只有 1（已审）/ -1（红冲），无草稿；照搬。
-- 【doc_type】TRANSFER/OTHER_IN/OTHER_OUT/DRAW/WDRAW/FINISHED_IN/FINISHED_OUT/CHECK
--   （WASTE 损耗老库 O_Waste 0 行，跳过；结构/枚举已留位。）
-- =====================================================================

SELECT set_config('app.business_identifier_legacy_import', 'on', true);
-- 清旧：仓库源流水 + 统一单据 + 余额（余额从 StockGoods 全量重建）
DELETE FROM stock_movements WHERE source_doc_type = 'STOCK_DOC';
-- V743(ADR-135) 重量调整账随库存账一起重建(导入后没有重量账链, 从第一笔新流水起算)。
DELETE FROM stock_weight_adjustments;
DELETE FROM stock_document_items;
DELETE FROM stock_documents;
DELETE FROM stock_balances;

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
    qty numeric(18,4), fact_qty numeric(18,4), total numeric(18,2),
    weight numeric(18,4), fact_weight numeric(33,4));   -- V80 即时库存重量（StockGoods.Weight/FactWeight）

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

-- ======================== 仓库对照表(ADR-145：只按审过的对照表解析，不补录仓库存根) ========================
CREATE TEMP TABLE warehouse_crosswalk_stage (
    legacy_id int, legacy_code text, legacy_name text, action text,
    target_code text, target_name text, target_defective boolean, note text);
\copy warehouse_crosswalk_stage FROM '/tmp/warehouse_crosswalk.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE warehouse_target_stage AS
SELECT crosswalk.legacy_id, crosswalk.action, target.id AS warehouse_id
FROM warehouse_crosswalk_stage crosswalk
LEFT JOIN warehouses target ON target.code = crosswalk.target_code AND NOT target.is_deleted
WHERE crosswalk.legacy_id IS NOT NULL;

-- 不迁的单据/明细/余额(对账按它扣减；全量导入时保留到运行结束)。
CREATE TEMP TABLE IF NOT EXISTS bootstrap_warehouse_exclusions (
    source_file text NOT NULL, source_row_id text NOT NULL, legacy_warehouse_id int,
    reason text NOT NULL, goods_legacy_id int, qty numeric, amount numeric);

DO $$
DECLARE
    missing TEXT;
    fallback TEXT := NULLIF(current_setting('uten.legacy_unassigned_warehouse_code', true), '');
BEGIN
    SELECT string_agg(DISTINCT lid::text, ', ') INTO missing
      FROM (SELECT stock_legacy_id AS lid FROM doc_stage UNION ALL
            SELECT to_stock_legacy_id FROM doc_stage UNION ALL
            SELECT stock_legacy FROM sg_stage) refs
     WHERE lid IS NOT NULL AND lid <> 0
       AND NOT EXISTS (SELECT 1 FROM warehouse_target_stage target
                        WHERE target.legacy_id = refs.lid
                          AND (target.action = 'DROP' OR target.warehouse_id IS NOT NULL));
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'legacy warehouses must resolve through warehouse_crosswalk.csv to an existing target: %', missing;
    END IF;
    IF fallback IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM warehouses WHERE code = fallback AND NOT is_deleted
          AND fn_warehouse_is_good_stock_leaf(id)) THEN
        RAISE EXCEPTION 'uten.legacy_unassigned_warehouse_code must name an enabled good-stock sub-warehouse: %', fallback;
    END IF;
END;
$$;

-- ======================== 自动补录缺失基础资料（此时 staging 满） ========================
-- 货品历史 FK 锚（盘点等可能引用已删货品）：legacy_id+name+auto_created=TRUE；V177/V181 要求选择器/BOM/MRP 隔离。
WITH candidates AS (
    SELECT DISTINCT lid
    FROM (SELECT goods_legacy_id AS lid FROM item_stage
          WHERE goods_legacy_id IS NOT NULL AND goods_legacy_id <> 0
          UNION ALL
          SELECT goods_legacy FROM sg_stage
          WHERE goods_legacy IS NOT NULL AND goods_legacy <> 0) t
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
      WHERE color_legacy_id IS NOT NULL AND color_legacy_id <> 0
      UNION ALL
      SELECT color_legacy FROM sg_stage
      WHERE color_legacy IS NOT NULL AND color_legacy <> 0) t
WHERE NOT EXISTS (SELECT 1 FROM colors c WHERE c.legacy_id = lid)
ON CONFLICT (legacy_id) DO NOTHING;

-- 仓库不补录(ADR-145)：老库已删除/已禁用的仓按对照表处理，见上方「仓库对照表」。

-- 货品的落仓子仓(SPLIT 用)：所属仓库是可选良品子仓才算数；否则用兜底子仓(如有)。
-- 放在货品补录之后：本模块才补建的历史货品锚(没有所属仓库)同样落到兜底子仓，不因为建表早于补录而漏掉。
CREATE TEMP TABLE goods_split_warehouse_stage AS
SELECT material.legacy_id AS goods_legacy_id,
       COALESCE(
           CASE WHEN fn_warehouse_is_good_stock_leaf(material.owning_warehouse_id)
                THEN material.owning_warehouse_id END,
           (SELECT fallback.id FROM warehouses fallback
             WHERE fallback.code = NULLIF(current_setting('uten.legacy_unassigned_warehouse_code', true), '')
               AND NOT fallback.is_deleted)) AS warehouse_id
FROM goods material
WHERE material.legacy_id IS NOT NULL;


-- StockGoods is itself a historical source even if the old O_* documents have
-- been removed. Never discard its nonzero facts silently or turn a missing real color
-- into the distinct no-color dimension. Invalid zero/null identities fail closed;
-- the reviewed crosswalk decides which warehouses are not carried over: balances on a
-- DROP warehouse are written to bootstrap_warehouse_exclusions below instead.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM sg_stage source
        LEFT JOIN warehouse_target_stage warehouse ON warehouse.legacy_id = source.stock_legacy
        LEFT JOIN goods material ON material.legacy_id = source.goods_legacy
        LEFT JOIN colors color ON color.legacy_id = NULLIF(source.color_legacy, 0)
        WHERE (COALESCE(source.fact_qty, source.qty, 0) <> 0
               OR COALESCE(source.fact_weight, source.weight, 0) <> 0
               OR COALESCE(source.total, 0) <> 0)
          AND warehouse.action IS DISTINCT FROM 'DROP'
          AND (warehouse.warehouse_id IS NULL OR material.id IS NULL
               OR (NULLIF(source.color_legacy, 0) IS NOT NULL AND color.id IS NULL))
    ) THEN
        RAISE EXCEPTION 'nonzero StockGoods facts require exact warehouse, goods and optional color identities';
    END IF;
END;
$$;

-- 落在老库已删除仓(DROP)的库存单据整张不迁(含调拨任一端)，明细随单据一起记进对账清单。
INSERT INTO bootstrap_warehouse_exclusions (source_file, source_row_id, legacy_warehouse_id, reason)
SELECT 'stock_' || lower(s.doc_type) || '_m.csv', s.legacy_id::text,
       CASE WHEN source_side.action = 'DROP' THEN s.stock_legacy_id ELSE s.to_stock_legacy_id END,
       'DROPPED_WAREHOUSE_DOCUMENT'
FROM doc_stage s
LEFT JOIN warehouse_target_stage source_side ON source_side.legacy_id = s.stock_legacy_id
LEFT JOIN warehouse_target_stage target_side ON target_side.legacy_id = NULLIF(s.to_stock_legacy_id, 0)
WHERE source_side.action = 'DROP' OR target_side.action = 'DROP';

INSERT INTO bootstrap_warehouse_exclusions (source_file, source_row_id, legacy_warehouse_id, reason,
    goods_legacy_id, qty, amount)
SELECT 'stock_' || lower(i.doc_type) || '_i.csv', i.legacy_id::text, excluded.legacy_warehouse_id,
       'DROPPED_WAREHOUSE_DOCUMENT', i.goods_legacy_id, i.qty, i.amount
FROM item_stage i
JOIN bootstrap_warehouse_exclusions excluded
  ON excluded.reason = 'DROPPED_WAREHOUSE_DOCUMENT'
 AND excluded.source_file = 'stock_' || lower(i.doc_type) || '_m.csv'
 AND excluded.source_row_id = i.bill_legacy_id::text;

-- 老库主仓 132(SPLIT)上的明细：货品没有可选的所属子仓(也没给兜底子仓)时这一行不迁。
INSERT INTO bootstrap_warehouse_exclusions (source_file, source_row_id, legacy_warehouse_id, reason,
    goods_legacy_id, qty, amount)
SELECT 'stock_' || lower(i.doc_type) || '_i.csv', i.legacy_id::text,
       CASE WHEN source_side.action = 'SPLIT' THEN d.stock_legacy_id ELSE d.to_stock_legacy_id END,
       'UNASSIGNED_OWNING_WAREHOUSE', i.goods_legacy_id, i.qty, i.amount
FROM item_stage i
JOIN doc_stage d ON d.legacy_id = i.bill_legacy_id AND d.doc_type = i.doc_type
LEFT JOIN warehouse_target_stage source_side ON source_side.legacy_id = d.stock_legacy_id
LEFT JOIN warehouse_target_stage target_side ON target_side.legacy_id = NULLIF(d.to_stock_legacy_id, 0)
LEFT JOIN goods_split_warehouse_stage split ON split.goods_legacy_id = i.goods_legacy_id
WHERE (source_side.action = 'SPLIT' OR target_side.action = 'SPLIT')
  AND COALESCE(source_side.action, '') <> 'DROP' AND COALESCE(target_side.action, '') <> 'DROP'
  AND split.warehouse_id IS NULL;

-- ======================== 人员补录：B_Worker → employees stub（融合键 legacy_id） ========================
-- 用户要求：老库有、新库没有就在员工表添加、显示名字（名字后带「（子类）」标记，sub_class 非空时）。
-- legacy_id = B_Worker.ID（融合键），full_name = Emp_Name，code='LEGACY-W-<id>'，
-- status='resigned'（老库很多人离职，默认离职；HR 以后在员工档案激活/补全真实信息），
-- department_id=DEPT_HR（HR 负责后续清理/分配真实部门），hire_date 占位，employment_type='regular'。
-- NOT EXISTS 守卫：用户已录真员工（同 legacy_id）优先，绝不覆盖；故重跑幂等、与真名单可融合。
-- sub_class 暂为 NULL（B_Worker 子类字段待 b_worker_columns.csv 确认后回填 SELECT）。
CREATE TEMP TABLE worker_stage (legacy_id int, name text, sub_class text);
\copy worker_stage FROM '/tmp/legacy_workers.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

CREATE TEMP TABLE operator_ref_stage (legacy_id int, name text);
\copy operator_ref_stage FROM '/tmp/legacy_operators_ref.csv' WITH (FORMAT csv, DELIMITER '|', HEADER true)

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
    worker_id, worker_legacy_id, maker_legacy_id, approver_legacy_id,
    maker_name_snapshot, approver_name_snapshot, ass_team,
    source_daily_report_id)
SELECT s.legacy_id, s.doc_type, s.bill_no, s.bill_date,
       (SELECT warehouse_id FROM warehouse_target_stage WHERE legacy_id = s.stock_legacy_id),
       (SELECT warehouse_id FROM warehouse_target_stage
         WHERE legacy_id = s.to_stock_legacy_id AND s.to_stock_legacy_id <> 0),
       (SELECT id FROM suppliers  WHERE legacy_id = s.supplier_legacy_id AND s.supplier_legacy_id <> 0),
       (SELECT id FROM clients    WHERE legacy_id = s.client_legacy_id  AND s.client_legacy_id  <> 0),
       NULLIF(s.plan_no,''), NULLIF(s.remark,''),
       COALESCE(s.total_original,0), COALESCE(s.total_original,0), s.status, FALSE,
       (SELECT e.id FROM employees e WHERE e.legacy_id = NULLIF(s.worker_legacy,0)),
       NULLIF(s.worker_legacy,0), NULLIF(s.maker_legacy,0), NULLIF(s.approver_legacy,0),
       (SELECT NULLIF(op.name,'') FROM operator_ref_stage op
        WHERE op.legacy_id = NULLIF(s.maker_legacy,0)),
       (SELECT NULLIF(op.name,'') FROM operator_ref_stage op
        WHERE op.legacy_id = NULLIF(s.approver_legacy,0)),
       NULLIF(s.ass_team,''),
       NULL::uuid  -- 历史自由文本不能证明来源报工关系，禁止按单号猜测
FROM doc_stage s
WHERE NOT EXISTS (SELECT 1 FROM bootstrap_warehouse_exclusions excluded
                   WHERE excluded.reason = 'DROPPED_WAREHOUSE_DOCUMENT'
                     AND excluded.source_file = 'stock_' || lower(s.doc_type) || '_m.csv'
                     AND excluded.source_row_id = s.legacy_id::text);

-- ======================== 统一明细（一条 INSERT，全 8 类） ========================
-- upstream（退料→领料）暂留空，下一步 UPDATE 回填（INSERT 时新 id 尚未生成）。
-- 明细仓(ADR-145)：单据头是老库主仓 132(SPLIT，记主仓 001)的一端，明细按货品所属子仓落仓。
INSERT INTO stock_document_items (
    legacy_id, doc_id, bill_type, bill_no, bill_date, line_no, goods_id, color_id, unit_id, warehouse_id,
    goods_code_snapshot, goods_name_snapshot, goods_snapshot_source, goods_snapshot_locked_at,
    unit_rate, qty, base_qty, price, amount_original, amount_local, weight, gift_qty,
    surplus_qty, count_qty, place, upstream_item_id, source_doc_no, remark)
SELECT s.legacy_id, d.id, s.doc_type, d.bill_no, d.bill_date,
       ROW_NUMBER() OVER (PARTITION BY s.bill_legacy_id, s.doc_type ORDER BY s.legacy_id),
       (SELECT id FROM goods  WHERE legacy_id = s.goods_legacy_id),
       (SELECT id FROM colors WHERE legacy_id = s.color_legacy_id),
       (SELECT id FROM units  WHERE legacy_id = s.unit_legacy_id),
       CASE WHEN EXISTS (SELECT 1 FROM warehouse_target_stage target
                          WHERE target.action = 'SPLIT'
                            AND target.legacy_id IN (source_doc.stock_legacy_id, source_doc.to_stock_legacy_id))
            THEN (SELECT split.warehouse_id FROM goods_split_warehouse_stage split
                   WHERE split.goods_legacy_id = s.goods_legacy_id) END,
       (SELECT code FROM goods WHERE legacy_id = s.goods_legacy_id),
       (SELECT name FROM goods WHERE legacy_id = s.goods_legacy_id),
       'LEGACY_IMPORT', CASE WHEN d.status <> 0 THEN now() ELSE NULL END,
       COALESCE(s.unit_rate,1), s.qty, ROUND(COALESCE(s.qty,0)*COALESCE(s.unit_rate,1),4),
       s.price, s.amount, s.amount,
       NULL::numeric,  -- 老库明细重量单位不可证明(不一定是千克), 不导入(V743/ADR-135)
       0,
       NULLIF(s.surplus_qty,0), NULLIF(s.count_qty,0),
       NULLIF(CAST(s.place_legacy_id AS TEXT),'0'),
       NULL,  -- upstream 回填见下
       NULLIF(s.source_doc_no,''), NULLIF(s.summary,'')
FROM item_stage s
JOIN stock_documents d ON d.legacy_id = s.bill_legacy_id AND d.doc_type = s.doc_type
JOIN doc_stage source_doc ON source_doc.legacy_id = s.bill_legacy_id AND source_doc.doc_type = s.doc_type
WHERE NOT EXISTS (SELECT 1 FROM bootstrap_warehouse_exclusions excluded
                   WHERE excluded.source_file = 'stock_' || lower(s.doc_type) || '_i.csv'
                     AND excluded.source_row_id = s.legacy_id::text);

-- 退料明细 → 领料明细 链路回填（upstream_legacy_id → DRAW 明细新 id）
UPDATE stock_document_items w SET upstream_item_id = i.id
FROM item_stage s, stock_document_items i
WHERE w.bill_type = 'WDRAW' AND w.legacy_id = s.legacy_id
  AND s.upstream_legacy_id IS NOT NULL AND s.upstream_legacy_id <> 0
  AND i.legacy_id = s.upstream_legacy_id AND i.bill_type = 'DRAW';

-- ======================== 重建库存余额（StockGoods → stock_balances） ========================
-- StockGoods 按「仓+货+色+年+库位」分行：QTY=年初余额(上年结转)、FactQTY=年末余额。
-- 当前余额 = 最新年(MAX year)的 FactQTY（同年多库位先 SUM，再取最新年；COALESCE 兜底 QTY）。
-- 旧实现误 SUM(所有年 QTY) 会跨年重复累加。当前余额只认最新年 FactQTY；
-- 仅当 FactQTY 本身为 NULL 时才显式回退 QTY。
-- 重量(V743/ADR-135)：库存重量统一为千克，老库 Weight/FactWeight 的单位不可证明，一律不导入
-- (NULL=不知道，从第一次称重/盘点起建立重量账)；只有基本单位本身是质量单位(kg/g/斤等，
-- unit_measurement_profiles.mass_unit_code)的货品按「数量 x 系数」精确得出重量。
-- 仓库(ADR-145)：先按老库仓取最新年，再经对照表落到目标仓——KEEP/MERGE 落目标子仓，
-- SPLIT(老库主仓 132)按货品所属子仓拆分，DROP(老库已删除仓)不迁；不迁的非零余额进对账清单。
-- 多个老库键落到同一目标键(如 132 拆到五金仓库 + 已禁用的 123 并入五金仓库)时合计。
CREATE TEMP TABLE legacy_latest_balance_stage ON COMMIT DROP AS
SELECT DISTINCT ON (stock_legacy, goods_legacy, color_legacy)
       stock_legacy, goods_legacy, color_legacy, year, fact_qty, total
FROM (
    SELECT g.stock_legacy, g.goods_legacy, g.color_legacy, g.year,
           COALESCE(SUM(COALESCE(g.fact_qty, g.qty)), 0) AS fact_qty,
           COALESCE(SUM(g.total), 0) AS total
    FROM sg_stage g
    GROUP BY 1, 2, 3, 4
) yearly
ORDER BY stock_legacy, goods_legacy, color_legacy, year DESC;

INSERT INTO bootstrap_warehouse_exclusions (source_file, source_row_id, legacy_warehouse_id, reason,
    goods_legacy_id, qty, amount)
SELECT 'stock_goods.csv',
       json_build_object('stock_legacy', latest.stock_legacy, 'goods_legacy', latest.goods_legacy,
                         'color_legacy', latest.color_legacy, 'year', latest.year)::text,
       latest.stock_legacy,
       CASE WHEN target.action = 'DROP' THEN 'DROPPED_WAREHOUSE_BALANCE' ELSE 'UNASSIGNED_OWNING_WAREHOUSE' END,
       latest.goods_legacy, latest.fact_qty, latest.total
FROM legacy_latest_balance_stage latest
JOIN warehouse_target_stage target ON target.legacy_id = latest.stock_legacy
LEFT JOIN goods_split_warehouse_stage split ON split.goods_legacy_id = latest.goods_legacy
WHERE (latest.fact_qty <> 0 OR latest.total <> 0)
  AND (target.action = 'DROP' OR (target.action = 'SPLIT' AND split.warehouse_id IS NULL));

CREATE TEMP TABLE latest_stock_balance_stage ON COMMIT DROP AS
SELECT CASE WHEN target.action = 'SPLIT' THEN split.warehouse_id ELSE target.warehouse_id END AS warehouse_id,
       material.id AS goods_id,
       (SELECT id FROM colors WHERE legacy_id = latest.color_legacy) AS color_id,
       max(latest.year) AS year,
       SUM(latest.fact_qty) AS fact_qty,
       SUM(latest.total) AS total
FROM legacy_latest_balance_stage latest
JOIN warehouse_target_stage target ON target.legacy_id = latest.stock_legacy AND target.action <> 'DROP'
JOIN goods material ON material.legacy_id = latest.goods_legacy
LEFT JOIN goods_split_warehouse_stage split ON split.goods_legacy_id = latest.goods_legacy
WHERE CASE WHEN target.action = 'SPLIT' THEN split.warehouse_id ELSE target.warehouse_id END IS NOT NULL
GROUP BY 1, 2, 3;

INSERT INTO stock_balances (warehouse_id, goods_id, color_id, qty, amount_local, weight, weight_estimated, last_movement_date)
SELECT latest.warehouse_id,
       latest.goods_id,
       latest.color_id,
       latest.fact_qty,
       latest.total,
       CASE
           WHEN latest.fact_qty > 0 AND profile.mass_unit_code IS NOT NULL
               THEN NULLIF(round(latest.fact_qty * fn_weight_unit_kg_factor(profile.mass_unit_code), 4), 0)
           ELSE NULL
       END,
       FALSE,
       now()
FROM latest_stock_balance_stage latest
JOIN goods material ON material.id = latest.goods_id
LEFT JOIN unit_measurement_profiles profile ON profile.unit_id = material.unit_id
WHERE latest.fact_qty <> 0
ON CONFLICT (warehouse_id, goods_id, color_id) DO UPDATE
SET qty = EXCLUDED.qty, amount_local = EXCLUDED.amount_local, weight = EXCLUDED.weight,
    weight_estimated = EXCLUDED.weight_estimated,
    last_movement_date = now(), updated_at = now();

-- ======================== 回填仓库流水（已审单据 → stock_movements，供报表） ========================
-- 流水仓(ADR-145)：明细带了拆分子仓就用它(老库主仓 132 一端)，否则用单据头仓。
INSERT INTO stock_movements (transaction_date, movement_type, source_doc_type, source_doc_id, source_item_id,
    goods_id, color_id, warehouse_id, direction, qty, unit_id, unit_rate, amount_local, remark)
SELECT d.bill_date::timestamptz,
       CASE d.doc_type WHEN 'OTHER_IN' THEN 11 WHEN 'OTHER_OUT' THEN 12
                       WHEN 'DRAW' THEN 5 WHEN 'WDRAW' THEN 6
                       WHEN 'FINISHED_IN' THEN 13 WHEN 'FINISHED_OUT' THEN 14 END,
       'STOCK_DOC', d.id, i.id, i.goods_id, i.color_id, COALESCE(i.warehouse_id, d.warehouse_id),
       CASE WHEN d.doc_type IN ('OTHER_IN','WDRAW','FINISHED_IN') THEN 1 ELSE -1 END,
       i.base_qty, i.unit_id, i.unit_rate, i.amount_local, NULLIF(i.remark,'')
FROM stock_document_items i JOIN stock_documents d ON d.id = i.doc_id
WHERE d.status = 1 AND d.doc_type IN ('OTHER_IN','OTHER_OUT','DRAW','WDRAW','FINISHED_IN','FINISHED_OUT')
  AND i.goods_id IS NOT NULL AND d.warehouse_id IS NOT NULL;

-- 调拨：调出仓 -8 / 调入仓 +7（两条）
INSERT INTO stock_movements (transaction_date, movement_type, source_doc_type, source_doc_id, source_item_id,
    goods_id, color_id, warehouse_id, direction, qty, unit_id, unit_rate, remark)
SELECT d.bill_date::timestamptz, 8, 'STOCK_DOC', d.id, i.id, i.goods_id, i.color_id,
       CASE WHEN d.warehouse_id = fn_warehouse_root_id() THEN i.warehouse_id ELSE d.warehouse_id END,
       -1, i.base_qty, i.unit_id, i.unit_rate, '调拨出'
FROM stock_document_items i JOIN stock_documents d ON d.id = i.doc_id
WHERE d.status = 1 AND d.doc_type = 'TRANSFER' AND d.warehouse_id IS NOT NULL AND i.goods_id IS NOT NULL;

INSERT INTO stock_movements (transaction_date, movement_type, source_doc_type, source_doc_id, source_item_id,
    goods_id, color_id, warehouse_id, direction, qty, unit_id, unit_rate, remark)
SELECT d.bill_date::timestamptz, 7, 'STOCK_DOC', d.id, i.id, i.goods_id, i.color_id,
       CASE WHEN d.to_warehouse_id = fn_warehouse_root_id() THEN i.warehouse_id ELSE d.to_warehouse_id END,
       1, i.base_qty, i.unit_id, i.unit_rate, '调拨入'
FROM stock_document_items i JOIN stock_documents d ON d.id = i.doc_id
WHERE d.status = 1 AND d.doc_type = 'TRANSFER' AND d.to_warehouse_id IS NOT NULL AND i.goods_id IS NOT NULL;

-- 盘点：surplus>0 盘盈入 +9 / surplus<0 盘亏出 -10（按盘盈亏量，非全量）
INSERT INTO stock_movements (transaction_date, movement_type, source_doc_type, source_doc_id, source_item_id,
    goods_id, color_id, warehouse_id, direction, qty, unit_id, unit_rate, remark)
SELECT d.bill_date::timestamptz,
       CASE WHEN i.surplus_qty > 0 THEN 9 ELSE 10 END,
       'STOCK_DOC', d.id, i.id, i.goods_id, i.color_id, COALESCE(i.warehouse_id, d.warehouse_id),
       CASE WHEN i.surplus_qty > 0 THEN 1 ELSE -1 END,
       ABS(i.surplus_qty), i.unit_id, i.unit_rate, NULLIF(i.remark,'')
FROM stock_document_items i JOIN stock_documents d ON d.id = i.doc_id
WHERE d.status = 1 AND d.doc_type = 'CHECK' AND i.surplus_qty IS NOT NULL AND i.surplus_qty <> 0
  AND i.goods_id IS NOT NULL AND d.warehouse_id IS NOT NULL;


-- ======================== 刷新仓库月度物化视图（防汇总报表空，同 sales 修复） ========================
REFRESH MATERIALIZED VIEW stock_monthly_mv;

-- ======================== 校验 ========================
SELECT '✔ 主表合计 ' || (SELECT count(*) FROM stock_documents) || ' / 明细 ' || (SELECT count(*) FROM stock_document_items) AS r
UNION ALL SELECT '余额行 '   || (SELECT count(*) FROM stock_balances)
UNION ALL SELECT '余额含重量 ' || (SELECT count(*) FROM stock_balances WHERE weight IS NOT NULL AND weight <> 0)
UNION ALL SELECT '仓库流水 ' || (SELECT count(*) FROM stock_movements WHERE source_doc_type='STOCK_DOC')
UNION ALL SELECT '货品历史引用锚（全库） ' || (SELECT count(*) FROM goods WHERE auto_created = TRUE)
UNION ALL SELECT '补录员工 ' || (SELECT count(*) FROM employees WHERE code LIKE 'LEGACY-W-%')
UNION ALL SELECT '经办员工UUID覆盖 ' || (SELECT count(*) FROM stock_documents WHERE worker_legacy_id IS NOT NULL AND worker_id IS NOT NULL)
UNION ALL SELECT '制单操作员快照覆盖 ' || (SELECT count(*) FROM stock_documents WHERE maker_legacy_id IS NOT NULL AND maker_name_snapshot IS NOT NULL)
UNION ALL SELECT '审核操作员快照覆盖 ' || (SELECT count(*) FROM stock_documents WHERE approver_legacy_id IS NOT NULL AND approver_name_snapshot IS NOT NULL)
UNION ALL SELECT '装配班组 ' || (SELECT count(*) FROM stock_documents WHERE ass_team IS NOT NULL)
UNION ALL SELECT '孤儿明细(无货品) ' || (SELECT count(*) FROM stock_document_items WHERE goods_id IS NULL)
UNION ALL SELECT '孤儿明细(无主表) ' || (SELECT count(*) FROM stock_document_items i WHERE NOT EXISTS (SELECT 1 FROM stock_documents d WHERE d.id=i.doc_id))
UNION ALL SELECT '退料挂领料 ' || (SELECT count(*) FROM stock_document_items WHERE bill_type='WDRAW' AND upstream_item_id IS NOT NULL)
UNION ALL SELECT '主仓上的流水(应为 0) ' || (SELECT count(*) FROM stock_movements WHERE source_doc_type='STOCK_DOC' AND warehouse_id = fn_warehouse_root_id())
UNION ALL SELECT '主仓上的余额(应为 0) ' || (SELECT count(*) FROM stock_balances WHERE warehouse_id = fn_warehouse_root_id())
UNION ALL SELECT '对照表不迁: ' || reason || ' ' || source_file || ' ' || count(*) || ' 行'
          FROM bootstrap_warehouse_exclusions GROUP BY reason, source_file;
