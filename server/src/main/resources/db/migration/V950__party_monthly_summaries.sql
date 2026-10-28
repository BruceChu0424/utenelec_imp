-- =====================================================================
-- V950：客户/供应商往来月度汇总 + 脏期间登记（B2 期初快照 · 迟到/红冲/核销）
-- =====================================================================
-- 往来事件流（FinancePartyStatementSql.events，AR=客户/AP=供应商）在 Java
-- 侧保持唯一权威定义；本表族是它的可重建月粒度投影：
--   · 7 个 AFTER 触发器在业务事务内把（side, party, 业务月）登记进
--     party_month_dirty——不用任何最大 ID / created_at 水位，迟到提交、
--     乱序提交、旧单改月、跨月红冲、抵销反转各自落在自己的脏期间；
--   · PartyMonthlySummaryService 按脏键在一致快照中从权威事件重算该
--     (party, month) 单元并删除脏键（同事务，崩溃可重试，天然幂等）；
--   · 读路径（对账单/年表）先自愈该 party 的脏键再查询，读取永远精确；
--   · month_start='1900-01-01' 是哨兵：整 party 全量重建。
-- 对账单期初从「全历史 UNBOUNDED PRECEDING 窗口」改为
-- 「已关月汇总 + 当月尾段 + 展示窗前缀」三段式（对齐 V408 账户流水范式）。
-- =====================================================================

CREATE TABLE party_monthly_summaries (
    id              UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    side            TEXT NOT NULL CHECK (side IN ('AR','AP')),
    party_id        UUID NOT NULL,
    currency_id     UUID,
    -- 空币种归并键：普通列、由写入方以 COALESCE 维护（生成列在部分投影夹具中不可复制）。
    currency_key    UUID NOT NULL,
    month_start     DATE NOT NULL,
    -- 与事件流同口径：net_* 逐行 (posted-settled) 求和，NULL 行整行跳过；
    -- null_original_count 记录会让原币滚动余额变 NULL（待核验）的行数。
    net_original    NUMERIC(38,6),
    posted_local_sum NUMERIC(38,4),
    settled_local_sum NUMERIC(38,4),
    net_local       NUMERIC(38,4),
    event_count     BIGINT NOT NULL,
    null_original_count BIGINT NOT NULL DEFAULT 0,
    last_rebuilt_at TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (side,party_id,month_start,currency_key),
    CONSTRAINT party_monthly_month_start_chk CHECK (
        month_start=date_trunc('month',month_start)::DATE),
    CONSTRAINT party_monthly_count_chk CHECK (event_count>0)
);

CREATE INDEX idx_party_monthly_party_month
    ON party_monthly_summaries(party_id,side,month_start);

COMMENT ON TABLE party_monthly_summaries IS
    'Rebuildable monthly projection of the dated AR/AP party event stream (Shanghai months); the Java-side events SQL stays the single authority';

CREATE TABLE party_month_dirty (
    side            TEXT NOT NULL CHECK (side IN ('AR','AP')),
    party_id        UUID NOT NULL,
    -- '1900-01-01' 哨兵 = 该 party 全量重建；其余值=具体待重算业务月。
    month_start     DATE NOT NULL,
    reason          TEXT,
    touched_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (side,party_id,month_start)
);

CREATE INDEX idx_party_month_dirty_queue ON party_month_dirty(touched_at);

COMMENT ON TABLE party_month_dirty IS
    'In-transaction dirty (side, party, month) registry for party monthly summaries; drained by recompute-from-authority, never by watermark';

-- ============ 共用登记函数 ============
CREATE OR REPLACE FUNCTION fn_touch_party_month_summary(
    p_side TEXT, p_party UUID, p_date DATE)
RETURNS VOID AS $$
DECLARE v_month DATE;
BEGIN
    IF p_party IS NULL OR p_date IS NULL
       OR p_side NOT IN ('AR','AP') THEN
        RETURN;
    END IF;
    v_month:=date_trunc('month',p_date)::DATE;
    INSERT INTO party_month_dirty(side,party_id,month_start,reason)
    VALUES (p_side,p_party,v_month,'SOURCE_CHANGE')
    ON CONFLICT (side,party_id,month_start) DO UPDATE
    SET touched_at=now();
END;
$$ LANGUAGE plpgsql;

-- ============ ① ar_ap_ledger：立账 / 反立账红冲 ============
-- 立账事件=业务账期（遗留导入=snapshotAsOfUtc 上海日）；红冲事件=deleted_at 上海日。
-- UPDATE 只看会改变事件流的列；核销回写 amount_settled 不影响事件流。
CREATE OR REPLACE FUNCTION fn_touch_party_summary_from_ledger()
RETURNS TRIGGER AS $$
DECLARE
    v_side TEXT; v_party UUID; v_date DATE;
BEGIN
    IF TG_OP<>'INSERT' THEN
        v_side:=CASE WHEN OLD.direction='AP' THEN 'AP' WHEN OLD.direction='AR' THEN 'AR' END;
        v_party:=CASE WHEN OLD.direction='AP' THEN OLD.supplier_id ELSE OLD.client_id END;
        v_date:=CASE
            WHEN OLD.status=1 AND NOT COALESCE(OLD.is_deleted,false) THEN
                CASE WHEN OLD.legacy_import_run_id IS NOT NULL
                     THEN ((OLD.legacy_source_resolution->>'snapshotAsOfUtc')::timestamptz
                           AT TIME ZONE 'Asia/Shanghai')::date
                     ELSE OLD.bill_date END
            WHEN OLD.status=-1 AND COALESCE(OLD.is_deleted,false)
                 AND OLD.deleted_at IS NOT NULL AND OLD.legacy_import_run_id IS NULL
                THEN (OLD.deleted_at AT TIME ZONE 'Asia/Shanghai')::date
            ELSE NULL END;
        PERFORM fn_touch_party_month_summary(v_side,v_party,v_date);
    END IF;
    IF TG_OP<>'DELETE' THEN
        v_side:=CASE WHEN NEW.direction='AP' THEN 'AP' WHEN NEW.direction='AR' THEN 'AR' END;
        v_party:=CASE WHEN NEW.direction='AP' THEN NEW.supplier_id ELSE NEW.client_id END;
        v_date:=CASE
            WHEN NEW.status=1 AND NOT COALESCE(NEW.is_deleted,false) THEN
                CASE WHEN NEW.legacy_import_run_id IS NOT NULL
                     THEN ((NEW.legacy_source_resolution->>'snapshotAsOfUtc')::timestamptz
                           AT TIME ZONE 'Asia/Shanghai')::date
                     ELSE NEW.bill_date END
            WHEN NEW.status=-1 AND COALESCE(NEW.is_deleted,false)
                 AND NEW.deleted_at IS NOT NULL AND NEW.legacy_import_run_id IS NULL
                THEN (NEW.deleted_at AT TIME ZONE 'Asia/Shanghai')::date
            ELSE NULL END;
        PERFORM fn_touch_party_month_summary(v_side,v_party,v_date);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_touch_party_summary_ledger
    AFTER INSERT OR DELETE OR UPDATE OF bill_date,direction,client_id,supplier_id,status,
        is_deleted,deleted_at,amount_original,amount_original_local,currency_id,
        legacy_import_run_id,legacy_source_resolution
    ON ar_ap_ledger
    FOR EACH ROW EXECUTE FUNCTION fn_touch_party_summary_from_ledger();

-- ============ ② finance_receipts：收款头（冲减应收事件 30/40） ============
CREATE OR REPLACE FUNCTION fn_touch_party_summary_from_receipts()
RETURNS TRIGGER AS $$
DECLARE
    v_reverse_old DATE; v_reverse_new DATE;
BEGIN
    IF TG_OP<>'INSERT' THEN
        v_reverse_old:=CASE WHEN OLD.status=-1
            THEN (COALESCE(OLD.reversed_at,OLD.updated_at) AT TIME ZONE 'Asia/Shanghai')::date END;
        PERFORM fn_touch_party_month_summary('AR',OLD.client_id,OLD.bill_date);
        PERFORM fn_touch_party_month_summary('AR',OLD.client_id,v_reverse_old);
    END IF;
    IF TG_OP<>'DELETE' THEN
        v_reverse_new:=CASE WHEN NEW.status=-1
            THEN (COALESCE(NEW.reversed_at,NEW.updated_at) AT TIME ZONE 'Asia/Shanghai')::date END;
        PERFORM fn_touch_party_month_summary('AR',NEW.client_id,NEW.bill_date);
        PERFORM fn_touch_party_month_summary('AR',NEW.client_id,v_reverse_new);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_touch_party_summary_receipts
    AFTER INSERT OR UPDATE OR DELETE ON finance_receipts
    FOR EACH ROW EXECUTE FUNCTION fn_touch_party_summary_from_receipts();

-- ============ ③ finance_receipt_lines：行金额变化影响头事件 ============
-- 辅助：按头 id 触碰其（客户, 账期/反审期）。
CREATE OR REPLACE FUNCTION fn_touch_party_summary_for_receipt(
    p_receipt UUID)
RETURNS VOID AS $$
DECLARE v_client UUID; v_bill DATE; v_status SMALLINT; v_rev TIMESTAMPTZ;
BEGIN
    IF p_receipt IS NULL THEN RETURN; END IF;
    SELECT client_id,bill_date,status,COALESCE(reversed_at,updated_at)
      INTO v_client,v_bill,v_status,v_rev
      FROM finance_receipts WHERE id=p_receipt;
    PERFORM fn_touch_party_month_summary('AR',v_client,v_bill);
    IF v_status=-1 THEN
        PERFORM fn_touch_party_month_summary('AR',v_client,
            (v_rev AT TIME ZONE 'Asia/Shanghai')::date);
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_touch_party_summary_from_receipt_lines()
RETURNS TRIGGER AS $$
DECLARE v_old UUID; v_new UUID;
BEGIN
    IF TG_OP='DELETE' THEN v_old:=OLD.receipt_id; END IF;
    IF TG_OP='INSERT' THEN v_new:=NEW.receipt_id; END IF;
    IF TG_OP='UPDATE' THEN v_old:=OLD.receipt_id; v_new:=NEW.receipt_id; END IF;
    PERFORM fn_touch_party_summary_for_receipt(v_old);
    PERFORM fn_touch_party_summary_for_receipt(v_new);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_touch_party_summary_receipt_lines
    AFTER INSERT OR UPDATE OR DELETE ON finance_receipt_lines
    FOR EACH ROW EXECUTE FUNCTION fn_touch_party_summary_from_receipt_lines();

-- ============ ④ finance_payments：付款头（AP） ============
CREATE OR REPLACE FUNCTION fn_touch_party_summary_from_payments()
RETURNS TRIGGER AS $$
DECLARE
    v_reverse_old DATE; v_reverse_new DATE;
BEGIN
    IF TG_OP<>'INSERT' THEN
        v_reverse_old:=CASE WHEN OLD.status=-1
            THEN (COALESCE(OLD.reversed_at,OLD.updated_at) AT TIME ZONE 'Asia/Shanghai')::date END;
        PERFORM fn_touch_party_month_summary('AP',OLD.supplier_id,OLD.bill_date);
        PERFORM fn_touch_party_month_summary('AP',OLD.supplier_id,v_reverse_old);
    END IF;
    IF TG_OP<>'DELETE' THEN
        v_reverse_new:=CASE WHEN NEW.status=-1
            THEN (COALESCE(NEW.reversed_at,NEW.updated_at) AT TIME ZONE 'Asia/Shanghai')::date END;
        PERFORM fn_touch_party_month_summary('AP',NEW.supplier_id,NEW.bill_date);
        PERFORM fn_touch_party_month_summary('AP',NEW.supplier_id,v_reverse_new);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_touch_party_summary_payments
    AFTER INSERT OR UPDATE OR DELETE ON finance_payments
    FOR EACH ROW EXECUTE FUNCTION fn_touch_party_summary_from_payments();

-- ============ ⑤ finance_payment_lines ============
CREATE OR REPLACE FUNCTION fn_touch_party_summary_for_payment(
    p_payment UUID)
RETURNS VOID AS $$
DECLARE v_supplier UUID; v_bill DATE; v_status SMALLINT; v_rev TIMESTAMPTZ;
BEGIN
    IF p_payment IS NULL THEN RETURN; END IF;
    SELECT supplier_id,bill_date,status,COALESCE(reversed_at,updated_at)
      INTO v_supplier,v_bill,v_status,v_rev
      FROM finance_payments WHERE id=p_payment;
    PERFORM fn_touch_party_month_summary('AP',v_supplier,v_bill);
    IF v_status=-1 THEN
        PERFORM fn_touch_party_month_summary('AP',v_supplier,
            (v_rev AT TIME ZONE 'Asia/Shanghai')::date);
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_touch_party_summary_from_payment_lines()
RETURNS TRIGGER AS $$
DECLARE v_old UUID; v_new UUID;
BEGIN
    IF TG_OP='DELETE' THEN v_old:=OLD.payment_id; END IF;
    IF TG_OP='INSERT' THEN v_new:=NEW.payment_id; END IF;
    IF TG_OP='UPDATE' THEN v_old:=OLD.payment_id; v_new:=NEW.payment_id; END IF;
    PERFORM fn_touch_party_summary_for_payment(v_old);
    PERFORM fn_touch_party_summary_for_payment(v_new);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_touch_party_summary_payment_lines
    AFTER INSERT OR UPDATE OR DELETE ON finance_payment_lines
    FOR EACH ROW EXECUTE FUNCTION fn_touch_party_summary_from_payment_lines();

-- ============ ⑥ customer_open_item_offsets：预收转销 50/60/70/80 ============
CREATE OR REPLACE FUNCTION fn_touch_party_summary_from_customer_offsets()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP<>'INSERT' THEN
        PERFORM fn_touch_party_month_summary('AR',OLD.client_id,OLD.effective_date);
        IF OLD.status='REVERSED' THEN
            PERFORM fn_touch_party_month_summary('AR',OLD.client_id,
                (OLD.reversed_at AT TIME ZONE 'Asia/Shanghai')::date);
        END IF;
    END IF;
    IF TG_OP<>'DELETE' THEN
        PERFORM fn_touch_party_month_summary('AR',NEW.client_id,NEW.effective_date);
        IF NEW.status='REVERSED' THEN
            PERFORM fn_touch_party_month_summary('AR',NEW.client_id,
                (NEW.reversed_at AT TIME ZONE 'Asia/Shanghai')::date);
        END IF;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_touch_party_summary_customer_offsets
    AFTER INSERT OR UPDATE OR DELETE ON customer_open_item_offsets
    FOR EACH ROW EXECUTE FUNCTION fn_touch_party_summary_from_customer_offsets();

-- ============ ⑦ supplier_open_item_offsets：应付抵销 ============
CREATE OR REPLACE FUNCTION fn_touch_party_summary_from_supplier_offsets()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP<>'INSERT' THEN
        PERFORM fn_touch_party_month_summary('AP',OLD.supplier_id,OLD.effective_date);
        IF OLD.status='REVERSED' THEN
            PERFORM fn_touch_party_month_summary('AP',OLD.supplier_id,
                (OLD.reversed_at AT TIME ZONE 'Asia/Shanghai')::date);
        END IF;
    END IF;
    IF TG_OP<>'DELETE' THEN
        PERFORM fn_touch_party_month_summary('AP',NEW.supplier_id,NEW.effective_date);
        IF NEW.status='REVERSED' THEN
            PERFORM fn_touch_party_month_summary('AP',NEW.supplier_id,
                (NEW.reversed_at AT TIME ZONE 'Asia/Shanghai')::date);
        END IF;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_touch_party_summary_supplier_offsets
    AFTER INSERT OR UPDATE OR DELETE ON supplier_open_item_offsets
    FOR EACH ROW EXECUTE FUNCTION fn_touch_party_summary_from_supplier_offsets();

-- ============ 既有往来单位：登记哨兵，由读路径自愈与后台排水完成回填 ============
-- 不在本迁移内重放事件流（Java 侧保留唯一权威 SQL）；首次读取某单位时
-- 同步重建其全部单元，后台排水覆盖其余单位。
INSERT INTO party_month_dirty(side,party_id,month_start,reason)
SELECT DISTINCT 'AR',ledger.client_id,DATE '1900-01-01','MIGRATION_SEED'
FROM ar_ap_ledger ledger WHERE ledger.client_id IS NOT NULL AND ledger.direction='AR'
UNION
SELECT DISTINCT 'AR',receipt.client_id,DATE '1900-01-01','MIGRATION_SEED'
FROM finance_receipts receipt WHERE receipt.client_id IS NOT NULL
UNION
SELECT DISTINCT 'AR',allocation.client_id,DATE '1900-01-01','MIGRATION_SEED'
FROM customer_open_item_offsets allocation WHERE allocation.client_id IS NOT NULL
UNION
SELECT DISTINCT 'AP',ledger.supplier_id,DATE '1900-01-01','MIGRATION_SEED'
FROM ar_ap_ledger ledger WHERE ledger.supplier_id IS NOT NULL AND ledger.direction='AP'
UNION
SELECT DISTINCT 'AP',payment.supplier_id,DATE '1900-01-01','MIGRATION_SEED'
FROM finance_payments payment WHERE payment.supplier_id IS NOT NULL
UNION
SELECT DISTINCT 'AP',allocation.supplier_id,DATE '1900-01-01','MIGRATION_SEED'
FROM supplier_open_item_offsets allocation WHERE allocation.supplier_id IS NOT NULL
ON CONFLICT DO NOTHING;

-- 审计登记（新表纳入审计目录）。
SELECT fn_audit_track_table('party_monthly_summaries','COLUMN_SCOPED','data_change',false,
    ARRAY['net_original','posted_local_sum','settled_local_sum','net_local',
          'event_count','null_original_count'],true);
SELECT fn_audit_track_table('party_month_dirty','COLUMN_SCOPED','data_change',false,
    ARRAY['touched_at'],true);
