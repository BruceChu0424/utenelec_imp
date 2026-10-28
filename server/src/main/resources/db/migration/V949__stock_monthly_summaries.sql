-- =====================================================================
-- V949：库存月度汇总投影（B2 期间汇总 · 变化维度对账基座）
-- =====================================================================
-- 复刻 V408 account_flow_monthly_summaries 的范式：stock_movements 流水
-- 保持唯一权威（事件溯源、只增不改），本表是可重建的月粒度投影：
--   · AFTER INSERT 触发器同事务增量维护（新流水永远落进它自己的业务月，
--     迟到、乱序提交天然正确，不依赖任何最大 ID / created_at 水位）；
--   · fn_rebuild_stock_monthly_summaries 排他 advisory 锁下全量重建；
--   · v_stock_monthly_integrity / fn_assert_* 提供独立原始事实核对；
--   · 每日余额对账改为「余额 ↔ Σ汇总」小表聚合，替代全流水无窗 SUM。
-- 取代 stock_monthly_mv 每 5 分钟 CONCURRENTLY 全量重算（该视图无任何
-- 应用读方；调度器退役见 Java 侧与 V951 注释，视图对象保留供诊断）。
-- 注意：业务清空（business_data_reset，已按 V915 封存）直接 DELETE
-- stock_movements 时不经过本触发器，隔离环境使用后须手工执行
-- fn_rebuild_stock_monthly_summaries() 重建；正式运行路径不受影响。
-- =====================================================================

CREATE TABLE stock_monthly_summaries (
    id              UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    month_start     DATE NOT NULL,
    movement_type   SMALLINT NOT NULL,
    goods_id        UUID NOT NULL REFERENCES goods(id) ON DELETE RESTRICT,
    warehouse_id    UUID NOT NULL REFERENCES warehouses(id) ON DELETE RESTRICT,
    color_id        UUID REFERENCES colors(id) ON DELETE RESTRICT,
    -- 无色货品归并键：普通列、由写入方以 COALESCE 维护（生成列在部分投影夹具中不可复制）。
    color_key       UUID NOT NULL,
    qty_net         NUMERIC(38,4) NOT NULL DEFAULT 0,
    amt_local_net   NUMERIC(38,4) NOT NULL DEFAULT 0,
    movement_count  BIGINT NOT NULL,
    first_ledger_seq BIGINT,
    last_ledger_seq BIGINT,
    last_rebuilt_at TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (month_start,movement_type,goods_id,warehouse_id,color_key),
    CONSTRAINT stock_monthly_month_start_chk CHECK (
        month_start=date_trunc('month',month_start)::DATE),
    CONSTRAINT stock_monthly_count_chk CHECK (movement_count>0)
);

-- 分块完整核对（按货品区间）与按货品取数的支撑索引。
CREATE INDEX idx_stock_monthly_summaries_goods ON stock_monthly_summaries(goods_id);

COMMENT ON TABLE stock_monthly_summaries IS
    'Audited, rebuildable signed monthly projection of the append-only stock_movements ledger (Shanghai month boundaries); qty_net/amt_local_net carry direction';

CREATE OR REPLACE FUNCTION fn_rebuild_stock_monthly_summaries()
RETURNS BIGINT AS $$
DECLARE v_rows BIGINT;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('uten:stock-monthly-summary',0));
    DELETE FROM stock_monthly_summaries;
    INSERT INTO stock_monthly_summaries(
        month_start,movement_type,goods_id,warehouse_id,color_id,color_key,
        qty_net,amt_local_net,movement_count,
        first_ledger_seq,last_ledger_seq,
        last_rebuilt_at,created_at,updated_at)
    SELECT date_trunc('month',m.transaction_date AT TIME ZONE 'Asia/Shanghai')::DATE,
           m.movement_type,m.goods_id,m.warehouse_id,m.color_id,
           COALESCE(m.color_id,'00000000-0000-0000-0000-000000000000'::uuid),
           SUM(m.qty*m.direction),
           SUM(COALESCE(m.amount_local,0)*m.direction),
           COUNT(*),
           MIN(m.ledger_seq),MAX(m.ledger_seq),
           now(),now(),now()
    FROM stock_movements m
    GROUP BY date_trunc('month',m.transaction_date AT TIME ZONE 'Asia/Shanghai')::DATE,
             m.movement_type,m.goods_id,m.warehouse_id,m.color_id;
    GET DIAGNOSTICS v_rows=ROW_COUNT;
    RETURN v_rows;
END;
$$ LANGUAGE plpgsql;

-- Build the whole projection from historical facts before enabling
-- incremental upkeep, then prove it against the raw ledger.
SELECT fn_rebuild_stock_monthly_summaries();

CREATE OR REPLACE FUNCTION fn_upsert_stock_monthly_summary()
RETURNS TRIGGER AS $$
DECLARE v_month DATE;
BEGIN
    PERFORM pg_advisory_xact_lock_shared(
        hashtextextended('uten:stock-monthly-summary',0));
    v_month:=date_trunc(
        'month',NEW.transaction_date AT TIME ZONE 'Asia/Shanghai')::DATE;
    INSERT INTO stock_monthly_summaries(
        month_start,movement_type,goods_id,warehouse_id,color_id,color_key,
        qty_net,amt_local_net,movement_count,
        first_ledger_seq,last_ledger_seq,
        last_rebuilt_at,created_at,updated_at)
    VALUES(
        v_month,NEW.movement_type,NEW.goods_id,NEW.warehouse_id,NEW.color_id,
        COALESCE(NEW.color_id,'00000000-0000-0000-0000-000000000000'::uuid),
        NEW.qty*NEW.direction,
        COALESCE(NEW.amount_local,0)*NEW.direction,
        1,
        NEW.ledger_seq,NEW.ledger_seq,
        NULL,now(),now())
    ON CONFLICT(month_start,movement_type,goods_id,warehouse_id,color_key) DO UPDATE
    SET qty_net=stock_monthly_summaries.qty_net+EXCLUDED.qty_net,
        amt_local_net=stock_monthly_summaries.amt_local_net+EXCLUDED.amt_local_net,
        movement_count=stock_monthly_summaries.movement_count+1,
        first_ledger_seq=CASE
            WHEN stock_monthly_summaries.first_ledger_seq IS NULL THEN EXCLUDED.first_ledger_seq
            WHEN EXCLUDED.first_ledger_seq IS NULL THEN stock_monthly_summaries.first_ledger_seq
            ELSE LEAST(stock_monthly_summaries.first_ledger_seq,EXCLUDED.first_ledger_seq) END,
        last_ledger_seq=GREATEST(
            stock_monthly_summaries.last_ledger_seq,EXCLUDED.last_ledger_seq),
        updated_at=now();
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_upsert_stock_monthly_summary
    AFTER INSERT ON stock_movements
    FOR EACH ROW EXECUTE FUNCTION fn_upsert_stock_monthly_summary();

-- 独立原始事实核对：整账本粒度 FULL OUTER JOIN（贵，按需/测试用；
-- 低峰分块核对走 StockMonthlyVerificationService 按货品区间）。
CREATE OR REPLACE VIEW v_stock_monthly_integrity AS
WITH ledger AS (
    SELECT date_trunc('month',m.transaction_date AT TIME ZONE 'Asia/Shanghai')::DATE
               AS month_start,
           m.movement_type,m.goods_id,m.warehouse_id,m.color_id,
           SUM(m.qty*m.direction) AS qty_net,
           SUM(COALESCE(m.amount_local,0)*m.direction) AS amt_local_net,
           COUNT(*) AS movement_count,
           MIN(m.ledger_seq) AS first_ledger_seq,
           MAX(m.ledger_seq) AS last_ledger_seq
    FROM stock_movements m
    GROUP BY date_trunc('month',m.transaction_date AT TIME ZONE 'Asia/Shanghai')::DATE,
             m.movement_type,m.goods_id,m.warehouse_id,m.color_id
)
SELECT COALESCE(ledger.month_start,summary.month_start) AS month_start,
       COALESCE(ledger.movement_type,summary.movement_type) AS movement_type,
       COALESCE(ledger.goods_id,summary.goods_id) AS goods_id,
       COALESCE(ledger.warehouse_id,summary.warehouse_id) AS warehouse_id,
       ledger.color_id AS ledger_color_id,
       summary.color_id AS summary_color_id,
       ledger.qty_net AS ledger_qty_net,
       summary.qty_net AS summary_qty_net,
       COALESCE(summary.qty_net,0)-COALESCE(ledger.qty_net,0) AS qty_difference,
       ledger.amt_local_net AS ledger_amt_local_net,
       summary.amt_local_net AS summary_amt_local_net,
       COALESCE(summary.amt_local_net,0)-COALESCE(ledger.amt_local_net,0)
           AS amt_local_difference,
       ledger.movement_count AS ledger_movement_count,
       summary.movement_count AS summary_movement_count,
       ledger.first_ledger_seq AS ledger_first_ledger_seq,
       summary.first_ledger_seq AS summary_first_ledger_seq,
       ledger.last_ledger_seq AS ledger_last_ledger_seq,
       summary.last_ledger_seq AS summary_last_ledger_seq,
       ledger.month_start IS NOT NULL
       AND summary.month_start IS NOT NULL
       AND ledger.color_id IS NOT DISTINCT FROM summary.color_id
       AND ledger.movement_type IS NOT DISTINCT FROM summary.movement_type
       AND ledger.goods_id IS NOT DISTINCT FROM summary.goods_id
       AND ledger.warehouse_id IS NOT DISTINCT FROM summary.warehouse_id
       AND ledger.month_start IS NOT DISTINCT FROM summary.month_start
       AND ledger.qty_net=summary.qty_net
       AND ledger.amt_local_net=summary.amt_local_net
       AND ledger.movement_count=summary.movement_count
       AND ledger.first_ledger_seq IS NOT DISTINCT FROM summary.first_ledger_seq
       AND ledger.last_ledger_seq IS NOT DISTINCT FROM summary.last_ledger_seq
           AS is_consistent
FROM ledger
FULL OUTER JOIN stock_monthly_summaries summary
  ON summary.month_start=ledger.month_start
 AND summary.movement_type IS NOT DISTINCT FROM ledger.movement_type
 AND summary.goods_id IS NOT DISTINCT FROM ledger.goods_id
 AND summary.warehouse_id IS NOT DISTINCT FROM ledger.warehouse_id
 AND summary.color_id IS NOT DISTINCT FROM ledger.color_id;

CREATE OR REPLACE FUNCTION fn_assert_stock_monthly_integrity()
RETURNS VOID AS $$
DECLARE v_invalid BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_invalid
    FROM v_stock_monthly_integrity integrity
    WHERE NOT integrity.is_consistent;
    IF v_invalid<>0 THEN
        RAISE EXCEPTION USING ERRCODE='23514',
            MESSAGE=format(
                'stock monthly summary differs from the movement ledger in %s cell(s)',
                v_invalid),
            CONSTRAINT='stock_monthly_integrity_guard';
    END IF;
END;
$$ LANGUAGE plpgsql;

SELECT fn_assert_stock_monthly_integrity();

-- 低峰分块完整核对的游程状态（单行）：记录最近核对的货品区间与结果，
-- 供运维与 StockMonthlyVerificationService 接续滚动。
CREATE TABLE stock_monthly_verification_state (
    singleton           BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    last_verified_goods UUID,
    last_run_at         TIMESTAMPTZ,
    last_chunk_rows     BIGINT,
    last_drift_count    BIGINT NOT NULL DEFAULT 0,
    full_cycles         BIGINT NOT NULL DEFAULT 0,
    last_error          TEXT
);
INSERT INTO stock_monthly_verification_state(singleton) VALUES (TRUE);

COMMENT ON TABLE stock_monthly_verification_state IS
    'Rolling cursor for chunked summary-vs-ledger verification over goods ranges; only records facts, never repairs';

-- 审计登记（新表纳入审计目录，与 V938 报表导出任务同形）。
-- 汇总表只审计重建戳：逐笔增量由被审计的 stock_movements 权威推导，
-- 若按数量列审计会让每笔过账多写一条审计（库存是全站最高频写入路径）。
SELECT fn_audit_track_table('stock_monthly_summaries','COLUMN_SCOPED','data_change',false,
    ARRAY['last_rebuilt_at'],true);
SELECT fn_audit_track_table('stock_monthly_verification_state','COLUMN_SCOPED','data_change',false,
    ARRAY['last_verified_goods','last_run_at','last_chunk_rows','last_drift_count','last_error'],true);
