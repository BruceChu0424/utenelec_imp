CREATE TABLE finance_expense_analysis_periods (
    period char(7) PRIMARY KEY CHECK(fn_finance_period_is_valid(period::text)),
    policy_confirmed boolean NOT NULL DEFAULT false, policy_reference text NOT NULL DEFAULT '',
    locked boolean NOT NULL DEFAULT false, row_version bigint NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid NOT NULL REFERENCES users(id),
    CHECK(NOT policy_confirmed OR length(btrim(policy_reference))>=8)
);
CREATE TABLE finance_operating_report_notes (
    period char(7) NOT NULL CHECK(fn_finance_period_is_valid(period::text)),
    line_key text NOT NULL CHECK(line_key ~ '^[A-Z][A-Z0-9_]{1,63}$'),
    remark text NOT NULL DEFAULT '' CHECK(length(remark)<=2000),
    variance_reason text NOT NULL DEFAULT '' CHECK(length(variance_reason)<=2000),
    row_version bigint NOT NULL DEFAULT 0, updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid NOT NULL REFERENCES users(id), PRIMARY KEY(period,line_key)
);
CREATE TABLE finance_expense_note_imports (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), actor_id uuid NOT NULL REFERENCES users(id),
    period char(7) NOT NULL CHECK(fn_finance_period_is_valid(period::text)),
    source_name text NOT NULL, sha256 text NOT NULL CHECK(sha256 ~ '^[0-9a-f]{64}$'),
    storage_provider text NOT NULL, storage_key text NOT NULL, storage_version text,storage_size bigint NOT NULL,
    preview jsonb NOT NULL, applied_at timestamptz, applied_result jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(actor_id,period,sha256),
    CHECK((applied_at IS NULL)=(applied_result IS NULL))
);

-- 410106 is a source pool, not another displayed manufacturing expense row. Freeze all
-- source identities and directions; positive and red pools must conserve separately.
CREATE VIEW v_finance_manufacturing_labor_pool AS
WITH facts AS (
    SELECT e.id,e.entry_date,fn_finance_manufacturing_occurrence(e.id) AS amount,to_char(e.entry_date,'YYYY-MM') AS period,
           fn_finance_expense_entry_fingerprint(e.id) AS fingerprint,
           jsonb_build_object('entryId',e.id,'date',e.entry_date,'billNo',e.source_bill_no,
              'styleId',e.style_id,'amountLocal',fn_finance_manufacturing_occurrence(e.id)::text,'fingerprint',fn_finance_expense_entry_fingerprint(e.id)) AS snapshot
    FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id
    WHERE NOT e.is_deleted AND public.fn_finance_gl_voucher_is_booked(v.id) AND e.amount<>0
      AND (fn_finance_manufacturing_occurrence(e.id)<>0 OR fn_finance_manufacturing_occurrence(e.id) IS NULL)
      AND NOT public.fn_finance_entry_is_pnl_closing(e.id)
      AND EXISTS(SELECT 1 FROM finance_report_line_bindings b JOIN finance_chart_code_styles m ON m.style_id=b.style_id
                 WHERE b.line_key='MFG_LABOR_CONTROL' AND b.binding_kind='STYLE' AND b.style_id=e.style_id AND m.code LIKE '410106%')
), bindings AS (
    SELECT string_agg(style_id::text,',' ORDER BY style_id) AS ids FROM finance_report_line_bindings
    WHERE line_key='MFG_LABOR_CONTROL' AND binding_kind='STYLE'
)
SELECT period,count(*) AS source_count,
       bool_or(amount IS NULL) AS pending,
       SUM(GREATEST(amount,0)) AS positive_amount,SUM(GREATEST(-amount,0)) AS negative_amount,
       encode(digest(COALESCE((SELECT ids FROM bindings),'')||'|'||string_agg(fingerprint,',' ORDER BY id),'sha256'),'hex') AS source_fingerprint,
       jsonb_agg(snapshot ORDER BY id) AS source_snapshot
FROM facts GROUP BY period;
CREATE TABLE finance_manufacturing_labor_splits (
    period char(7) PRIMARY KEY CHECK(fn_finance_period_is_valid(period::text)),
    source_fingerprint text NOT NULL CHECK(source_fingerprint ~ '^[0-9a-f]{64}$'),source_snapshot jsonb NOT NULL,
    direct_positive numeric NOT NULL CHECK(direct_positive>=0 AND fn_financial_book_amount_is_exact(direct_positive)),indirect_positive numeric NOT NULL CHECK(indirect_positive>=0 AND fn_financial_book_amount_is_exact(indirect_positive)),
    direct_negative numeric NOT NULL CHECK(direct_negative>=0 AND fn_financial_book_amount_is_exact(direct_negative)),indirect_negative numeric NOT NULL CHECK(indirect_negative>=0 AND fn_financial_book_amount_is_exact(indirect_negative)),
    source_reference text NOT NULL CHECK(length(btrim(source_reference))>=4),reviewed boolean NOT NULL DEFAULT false,
    request_fingerprint text NOT NULL,row_version bigint NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now(),updated_by uuid NOT NULL REFERENCES users(id)
);
CREATE FUNCTION fn_guard_finance_manufacturing_labor_split() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE source record;
BEGIN
    SELECT * INTO source FROM v_finance_manufacturing_labor_pool WHERE period=NEW.period::text;
    IF source.source_fingerprint IS NULL OR source.source_fingerprint IS DISTINCT FROM NEW.source_fingerprint THEN
        RAISE EXCEPTION '工资源池已变化，请重新核对原分录' USING ERRCODE='23514';
    END IF;
    IF NEW.reviewed AND (NEW.direct_positive+NEW.indirect_positive<>source.positive_amount
       OR NEW.direct_negative+NEW.indirect_negative<>source.negative_amount OR source.pending) THEN
        RAISE EXCEPTION '工资正向与红字分配须分别守恒' USING ERRCODE='23514';
    END IF;
    NEW.source_snapshot:=source.source_snapshot;
    RETURN NEW;
END;
$$;
CREATE TRIGGER finance_manufacturing_labor_split_guard BEFORE INSERT OR UPDATE ON finance_manufacturing_labor_splits
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_manufacturing_labor_split();
SELECT fn_audit_track_table('finance_expense_analysis_periods','COLUMN_SCOPED','data_change',false,ARRAY['period','policy_confirmed','locked','updated_by'],true,NULL);
SELECT fn_audit_track_table('finance_operating_report_notes','COLUMN_SCOPED','data_change',false,ARRAY['period','line_key','updated_by'],true,NULL);
SELECT fn_audit_track_table('finance_expense_note_imports','COLUMN_SCOPED','data_change',false,ARRAY['id','actor_id','period','sha256','applied_at'],true,NULL);
SELECT fn_audit_track_table('finance_manufacturing_labor_splits','COLUMN_SCOPED','data_change',false,ARRAY['period','source_fingerprint','request_fingerprint','reviewed','updated_by'],true,NULL);
