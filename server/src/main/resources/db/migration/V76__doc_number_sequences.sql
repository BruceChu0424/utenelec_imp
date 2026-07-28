-- =====================================================================
-- V76：单据号自动生成序列表（DocNumberService）
-- =====================================================================
-- 目的：取代"前端手填单据号"。后端 Service.create() 时原子取号，
--   格式 [2位前缀][YYMM][4位月内顺序号]，如 CD26070001。
--   顺序号按 (prefix, period=YYMM) 月度归零。
--
-- 并发：INSERT ... ON CONFLICT DO UPDATE ... RETURNING 单语句原子取行锁自增
--   （PG 行锁微秒级，无死锁面）。回滚 txn 会跳号——可接受（单号要唯一+单调，不要无缝）。
--
-- period/seq 都从 bill_no 本身解析（不依赖 bill_date，避免单据日期与号内月份不符时错桶）。
-- 回填用 ON CONFLICT ... GREATEST 保证可重入（重跑安全、取最大）。
-- 详见 plans/witty-imagining-reef.md Workstream A。
-- =====================================================================

CREATE TABLE doc_number_sequences (
    prefix      TEXT NOT NULL,          -- 2 字符，如 'CD'
    period      INTEGER NOT NULL,        -- YY*100+MM，如 2607
    last_seq    INTEGER NOT NULL DEFAULT 0,
    CONSTRAINT pk_doc_number_sequences PRIMARY KEY (prefix, period)
);

COMMENT ON TABLE doc_number_sequences IS '单据号月度序列；每 (prefix, period) 一行，DocNumberService 原子自增。';

-- ====================== 回填：扫描各表现有 bill_no 播种 last_seq ======================
-- 模板：period = 号内 YYMM，seq = 号内末4位；仅匹配 ^前缀+8位数字$ 的标准号。
-- 未知/非标准号不匹配 → 不播种（其原号保留不回写，未来同前缀号从 1 起，几乎不会撞）。

-- ---- 采购（CJ 收货与仓库产成品进仓老数据共用 CJ，合并取最大；产成品进仓后续改用 CR）----
INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'CJ', period, MAX(seq) FROM (
    SELECT substring(bill_no from 'CJ([0-9]{4})')::int          AS period,
           MAX(substring(bill_no from 'CJ[0-9]{4}([0-9]{4})')::int) AS seq
    FROM purchase_receipts WHERE bill_no ~ '^CJ[0-9]{8}$' GROUP BY 1
    UNION ALL
    SELECT substring(bill_no from 'CJ([0-9]{4})')::int,
           MAX(substring(bill_no from 'CJ[0-9]{4}([0-9]{4})')::int)
    FROM stock_documents WHERE doc_type='FINISHED_IN' AND bill_no ~ '^CJ[0-9]{8}$' GROUP BY 1
) s GROUP BY period
ON CONFLICT (prefix, period) DO UPDATE
    SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'CS', substring(bill_no from 'CS([0-9]{4})')::int,
       MAX(substring(bill_no from 'CS[0-9]{4}([0-9]{4})')::int)
FROM purchase_requests WHERE bill_no ~ '^CS[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'CD', substring(bill_no from 'CD([0-9]{4})')::int,
       MAX(substring(bill_no from 'CD[0-9]{4}([0-9]{4})')::int)
FROM purchase_orders WHERE bill_no ~ '^CD[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'CT', substring(bill_no from 'CT([0-9]{4})')::int,
       MAX(substring(bill_no from 'CT[0-9]{4}([0-9]{4})')::int)
FROM purchase_returns WHERE bill_no ~ '^CT[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

-- ---- 销售 ----
INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'XD', substring(bill_no from 'XD([0-9]{4})')::int,
       MAX(substring(bill_no from 'XD[0-9]{4}([0-9]{4})')::int)
FROM sales_orders WHERE bill_no ~ '^XD[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'XC', substring(bill_no from 'XC([0-9]{4})')::int,
       MAX(substring(bill_no from 'XC[0-9]{4}([0-9]{4})')::int)
FROM sales_shipments WHERE bill_no ~ '^XC[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'OC', substring(bill_no from 'OC([0-9]{4})')::int,
       MAX(substring(bill_no from 'OC[0-9]{4}([0-9]{4})')::int)
FROM sales_other_shipments WHERE bill_no ~ '^OC[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'XT', substring(bill_no from 'XT([0-9]{4})')::int,
       MAX(substring(bill_no from 'XT[0-9]{4}([0-9]{4})')::int)
FROM sales_returns WHERE bill_no ~ '^XT[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

-- XB 销售报价（老库 0 行，无回填；新铸前缀，从 1 起）

-- ---- 仓库 stock_documents（按 doc_type 区分前缀）----
INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'CB', substring(bill_no from 'CB([0-9]{4})')::int,
       MAX(substring(bill_no from 'CB[0-9]{4}([0-9]{4})')::int)
FROM stock_documents WHERE doc_type='TRANSFER' AND bill_no ~ '^CB[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'QR', substring(bill_no from 'QR([0-9]{4})')::int,
       MAX(substring(bill_no from 'QR[0-9]{4}([0-9]{4})')::int)
FROM stock_documents WHERE doc_type='OTHER_IN' AND bill_no ~ '^QR[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'QC', substring(bill_no from 'QC([0-9]{4})')::int,
       MAX(substring(bill_no from 'QC[0-9]{4}([0-9]{4})')::int)
FROM stock_documents WHERE doc_type='OTHER_OUT' AND bill_no ~ '^QC[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'SL', substring(bill_no from 'SL([0-9]{4})')::int,
       MAX(substring(bill_no from 'SL[0-9]{4}([0-9]{4})')::int)
FROM stock_documents WHERE doc_type='DRAW' AND bill_no ~ '^SL[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'ST', substring(bill_no from 'ST([0-9]{4})')::int,
       MAX(substring(bill_no from 'ST[0-9]{4}([0-9]{4})')::int)
FROM stock_documents WHERE doc_type='WDRAW' AND bill_no ~ '^ST[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'CC', substring(bill_no from 'CC([0-9]{4})')::int,
       MAX(substring(bill_no from 'CC[0-9]{4}([0-9]{4})')::int)
FROM stock_documents WHERE doc_type='FINISHED_OUT' AND bill_no ~ '^CC[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'PQ', substring(bill_no from 'PQ([0-9]{4})')::int,
       MAX(substring(bill_no from 'PQ[0-9]{4}([0-9]{4})')::int)
FROM stock_documents WHERE doc_type='CHECK' AND bill_no ~ '^PQ[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

-- CR 产成品进仓（新铸前缀，取代老库与采购收货共用的 CJ；老 CJ 数据已并入 CJ 序列，CR 无回填，从 1 起）

-- ---- 委外 ----
INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'EC', substring(bill_no from 'EC([0-9]{4})')::int,
       MAX(substring(bill_no from 'EC[0-9]{4}([0-9]{4})')::int)
FROM subcontract_material_issues WHERE bill_no ~ '^EC[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'EJ', substring(bill_no from 'EJ([0-9]{4})')::int,
       MAX(substring(bill_no from 'EJ[0-9]{4}([0-9]{4})')::int)
FROM subcontract_receipts WHERE bill_no ~ '^EJ[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'ET', substring(bill_no from 'ET([0-9]{4})')::int,
       MAX(substring(bill_no from 'ET[0-9]{4}([0-9]{4})')::int)
FROM subcontract_returns WHERE bill_no ~ '^ET[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

-- ER 委外材料退 / EW 委外损耗：新铸前缀（老库无标准号），从 1 起

-- ---- 钱流 ----
INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'XS', substring(bill_no from 'XS([0-9]{4})')::int,
       MAX(substring(bill_no from 'XS[0-9]{4}([0-9]{4})')::int)
FROM finance_receipts WHERE bill_no ~ '^XS[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'CF', substring(bill_no from 'CF([0-9]{4})')::int,
       MAX(substring(bill_no from 'CF[0-9]{4}([0-9]{4})')::int)
FROM finance_payments WHERE bill_no ~ '^CF[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'YF', substring(bill_no from 'YF([0-9]{4})')::int,
       MAX(substring(bill_no from 'YF[0-9]{4}([0-9]{4})')::int)
FROM finance_expenses WHERE bill_no ~ '^YF[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'QS', substring(bill_no from 'QS([0-9]{4})')::int,
       MAX(substring(bill_no from 'QS[0-9]{4}([0-9]{4})')::int)
FROM finance_other_incomes WHERE bill_no ~ '^QS[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'YC', substring(bill_no from 'YC([0-9]{4})')::int,
       MAX(substring(bill_no from 'YC[0-9]{4}([0-9]{4})')::int)
FROM finance_bank_transfers WHERE bill_no ~ '^YC[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);

-- ---- 生产 ----
INSERT INTO doc_number_sequences (prefix, period, last_seq)
SELECT 'SJ', substring(bill_no from 'SJ([0-9]{4})')::int,
       MAX(substring(bill_no from 'SJ[0-9]{4}([0-9]{4})')::int)
FROM production_plans WHERE bill_no ~ '^SJ[0-9]{8}$' GROUP BY 1, 2
ON CONFLICT (prefix, period) DO UPDATE SET last_seq = GREATEST(doc_number_sequences.last_seq, EXCLUDED.last_seq);
