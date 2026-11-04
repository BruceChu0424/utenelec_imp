-- Attribution is a reviewed analysis of existing ledger facts, never another posting authority.
CREATE TABLE finance_sales_expense_groups (
    id uuid PRIMARY KEY, period char(7) NOT NULL CHECK(fn_finance_period_is_valid(period::text)),
    label_snapshot text NOT NULL CHECK(length(btrim(label_snapshot)) BETWEEN 1 AND 240),
    employee_id uuid REFERENCES employees(id), channel text CHECK(channel IN('OEM','FOREIGN','DOMESTIC','MANAGEMENT')),
    sales_amount_local numeric CHECK(sales_amount_local IS NULL OR fn_financial_book_amount_is_exact(sales_amount_local)), sales_confirmed boolean NOT NULL DEFAULT false,
    reviewed boolean NOT NULL DEFAULT false, source_reference text NOT NULL DEFAULT '',
    sort_order integer NOT NULL DEFAULT 0, row_version bigint NOT NULL DEFAULT 0,
    request_fingerprint text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid NOT NULL REFERENCES users(id),
    UNIQUE(period,label_snapshot),
    CHECK(NOT reviewed OR length(btrim(source_reference))>=4),
    CHECK(NOT sales_confirmed OR sales_amount_local IS NOT NULL)
);
CREATE INDEX idx_finance_sales_expense_groups_period ON finance_sales_expense_groups(period,sort_order,id);



-- Manufacturing occurrence is the original debit (including signed red values).
-- Reverse a proved debit as a negative occurrence; reversing a cost-transfer credit
-- restores the balance without inventing a new cost. Unproved/cyclic links are unknown.
CREATE FUNCTION fn_finance_direction_occurrence(p_id uuid,p_direction integer) RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE current_entry gl_entries%ROWTYPE; source_entry gl_entries%ROWTYPE; current_voucher gl_vouchers%ROWTYPE;
        sign numeric:=1; seen uuid[]:=ARRAY[]::uuid[]; depth integer:=0; matches integer;
BEGIN
    IF p_direction IS NULL OR p_direction NOT IN(1,-1) THEN RETURN NULL;END IF;
    SELECT * INTO current_entry FROM gl_entries WHERE id=p_id AND NOT is_deleted;
    IF current_entry.id IS NULL THEN RETURN NULL;END IF;
    LOOP
        SELECT * INTO current_voucher FROM gl_vouchers WHERE id=current_entry.voucher_id;
        IF NOT public.fn_finance_gl_voucher_is_booked(current_voucher.id) OR current_voucher.id=ANY(seen) OR depth>16 THEN RETURN NULL;END IF;
        IF current_voucher.reversal_of_voucher_id IS NULL THEN
            RETURN CASE WHEN current_entry.direction=p_direction THEN sign*current_entry.amount ELSE 0 END;
        END IF;
        seen:=array_append(seen,current_voucher.id);depth:=depth+1;
        IF NOT EXISTS(SELECT 1 FROM gl_vouchers original WHERE original.id=current_voucher.reversal_of_voucher_id
            AND original.reversed_by_voucher_id=current_voucher.id AND public.fn_finance_gl_voucher_is_booked(original.id)) THEN RETURN NULL;END IF;
        SELECT count(*) INTO matches FROM gl_entries original WHERE original.voucher_id=current_voucher.reversal_of_voucher_id
            AND NOT original.is_deleted AND original.style_id=current_entry.style_id AND original.line_no=current_entry.line_no
            AND original.direction=-current_entry.direction AND original.amount=current_entry.amount;
        IF matches<>1 THEN RETURN NULL;END IF;
        SELECT * INTO source_entry FROM gl_entries original WHERE original.voucher_id=current_voucher.reversal_of_voucher_id
            AND NOT original.is_deleted AND original.style_id=current_entry.style_id AND original.line_no=current_entry.line_no
            AND original.direction=-current_entry.direction AND original.amount=current_entry.amount;
        current_entry:=source_entry;sign:=-sign;
    END LOOP;
END;
$$;
CREATE FUNCTION fn_finance_debit_occurrence(p_id uuid) RETURNS numeric LANGUAGE sql STABLE AS $$SELECT fn_finance_direction_occurrence(p_id,1)$$;
CREATE FUNCTION fn_finance_credit_occurrence(p_id uuid) RETURNS numeric LANGUAGE sql STABLE AS $$SELECT fn_finance_direction_occurrence(p_id,-1)$$;


-- Retain existing report callers; debit/reversal identity has one implementation.
CREATE FUNCTION fn_finance_manufacturing_occurrence(p_id uuid) RETURNS numeric LANGUAGE sql STABLE AS $$
 SELECT fn_finance_debit_occurrence(p_id);
$$;

CREATE FUNCTION fn_finance_expense_entry_fingerprint(p_id uuid) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT encode(digest(jsonb_build_array(e.id,e.voucher_id,e.style_id,e.direction,e.amount::text,e.entry_date,
           e.source_doc_type,e.source_doc_id,e.source_bill_no,e.line_no,e.is_deleted,public.fn_finance_gl_voucher_is_booked(v.id),v.reversal_of_voucher_id,fn_finance_manufacturing_occurrence(e.id))::text,'sha256'),'hex')
    FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id WHERE e.id=p_id;
$$;

-- No FK to gl_entries: native AUTO rebuilds may replace their rows. The frozen fingerprint and
-- original snapshot remain as evidence; a replaced/reversed source makes attribution pending.
CREATE TABLE finance_sales_expense_assignments (
    entry_id uuid PRIMARY KEY, period char(7) NOT NULL CHECK(fn_finance_period_is_valid(period::text)),
    source_fingerprint text NOT NULL CHECK(source_fingerprint ~ '^[0-9a-f]{64}$'),
    source_snapshot jsonb NOT NULL, allocations jsonb NOT NULL CHECK(jsonb_typeof(allocations)='array'),
    source_reference text NOT NULL CHECK(length(btrim(source_reference))>=4),
    request_fingerprint text NOT NULL, row_version bigint NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid NOT NULL REFERENCES users(id)
);
CREATE INDEX idx_finance_sales_expense_assignments_period ON finance_sales_expense_assignments(period);

CREATE FUNCTION fn_guard_finance_sales_expense_assignment() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE original numeric; source_period text; fingerprint text; item jsonb; allocated numeric:=0; value numeric;
BEGIN
    SELECT e.direction*e.amount,to_char(e.entry_date,'YYYY-MM'),fn_finance_expense_entry_fingerprint(e.id)
      INTO original,source_period,fingerprint
    FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id
    WHERE e.id=NEW.entry_id AND NOT e.is_deleted AND public.fn_finance_gl_voucher_is_booked(v.id)
      AND NOT public.fn_finance_entry_is_pnl_closing(e.id)
      AND EXISTS(SELECT 1 FROM finance_report_line_bindings b
                 WHERE b.line_key='SALES_FEE' AND b.binding_kind='STYLE' AND b.style_id=e.style_id)
    FOR SHARE OF e,v;
    IF fingerprint IS NULL OR fingerprint IS DISTINCT FROM NEW.source_fingerprint OR source_period<>NEW.period::text THEN
        RAISE EXCEPTION '销售费用来源已变化，请重新核对原分录' USING ERRCODE='23514';
    END IF;
    IF jsonb_array_length(NEW.allocations)=0 OR jsonb_array_length(NEW.allocations)>500 THEN
        RAISE EXCEPTION '每笔来源须有1至500条归属分配' USING ERRCODE='23514';
    END IF;
    FOR item IN SELECT jsonb_array_elements(NEW.allocations) LOOP
        IF item->>'feeKey' NOT IN('SALARY','SOCIAL','FREIGHT','OTHER','TRAVEL','ENTERTAIN','AGENCY','EXHIBITION','LOADING','MATERIAL','REBATE','COMPENSATION')
           OR (length(COALESCE(item->>'amountLocal',''))>256 OR COALESCE(item->>'amountLocal','')!~ '^-?[0-9]+(\.[0-9]+)?$') THEN
            RAISE EXCEPTION '费用项目或分摊金额无效' USING ERRCODE='23514';
        END IF;
        value:=(item->>'amountLocal')::numeric;
        IF NOT fn_financial_book_amount_is_exact(value) THEN RAISE EXCEPTION '分配金额超出共享账面精度范围' USING ERRCODE='23514';END IF;
        IF original*value<0 THEN RAISE EXCEPTION '分配方向必须与原分录一致' USING ERRCODE='23514'; END IF;
        IF NOT EXISTS(SELECT 1 FROM finance_sales_expense_groups g WHERE g.id=(item->>'groupId')::uuid AND g.period=NEW.period) THEN
            RAISE EXCEPTION '费用分组不属于来源期间' USING ERRCODE='23514';
        END IF;
        IF NULLIF(item->>'clientId','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM clients WHERE id=(item->>'clientId')::uuid) THEN
            RAISE EXCEPTION '费用客户不存在' USING ERRCODE='23514';
        END IF;
        allocated:=allocated+value;
    END LOOP;
    IF allocated<>original THEN RAISE EXCEPTION '分配合计必须等于原分录有符号本币金额' USING ERRCODE='23514'; END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER finance_sales_expense_assignment_guard BEFORE INSERT OR UPDATE ON finance_sales_expense_assignments
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_sales_expense_assignment();

CREATE VIEW v_finance_sales_expense_pool AS
SELECT e.id AS entry_id,to_char(e.entry_date,'YYYY-MM') AS period,e.direction*e.amount AS amount_local,
       e.entry_date,e.style_id,e.source_bill_no,fn_finance_expense_entry_fingerprint(e.id) AS source_fingerprint,
       COALESCE(a.allocations,'[]'::jsonb) AS allocations,
       (a.entry_id IS NULL OR a.source_fingerprint IS DISTINCT FROM fn_finance_expense_entry_fingerprint(e.id)
         OR a.period::text<>to_char(e.entry_date,'YYYY-MM') OR EXISTS(
            SELECT 1 FROM jsonb_array_elements(COALESCE(a.allocations,'[]'::jsonb)) line
            LEFT JOIN finance_sales_expense_groups g ON g.id=(line->>'groupId')::uuid
            WHERE g.id IS NULL OR g.period::text<>to_char(e.entry_date,'YYYY-MM') OR NOT g.reviewed)) AS pending
FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id
LEFT JOIN finance_sales_expense_assignments a ON a.entry_id=e.id
WHERE NOT e.is_deleted AND public.fn_finance_gl_voucher_is_booked(v.id) AND e.amount<>0
  AND NOT public.fn_finance_entry_is_pnl_closing(e.id)
  AND EXISTS(SELECT 1 FROM finance_report_line_bindings b WHERE b.line_key='SALES_FEE' AND b.binding_kind='STYLE' AND b.style_id=e.style_id)
UNION ALL
SELECT a.entry_id,a.period::text,NULL::numeric,(a.source_snapshot->>'date')::date,e.style_id,
       a.source_snapshot->>'billNo',NULL::text,a.allocations,true
FROM finance_sales_expense_assignments a LEFT JOIN gl_entries e ON e.id=a.entry_id
WHERE NOT EXISTS(SELECT 1 FROM gl_entries current_entry JOIN gl_vouchers v ON v.id=current_entry.voucher_id
    WHERE current_entry.id=a.entry_id AND NOT current_entry.is_deleted AND public.fn_finance_gl_voucher_is_booked(v.id)
      AND current_entry.amount<>0 AND NOT public.fn_finance_entry_is_pnl_closing(current_entry.id)
      AND EXISTS(SELECT 1 FROM finance_report_line_bindings b WHERE b.line_key='SALES_FEE' AND b.binding_kind='STYLE' AND b.style_id=current_entry.style_id));

CREATE VIEW v_finance_sales_expense_period_coverage AS
SELECT period,CASE WHEN bool_or(amount_local IS NULL) THEN NULL ELSE SUM(amount_local) END AS amount_local,count(*) AS source_count,bool_or(pending) AS pending
FROM v_finance_sales_expense_pool GROUP BY period;

CREATE VIEW v_finance_sales_expense_allocation_facts AS
SELECT p.period,(line->>'groupId')::uuid AS group_id,line->>'feeKey' AS fee_key,
       NULLIF(line->>'clientId','')::uuid AS client_id,(line->>'amountLocal')::numeric AS amount_local
FROM v_finance_sales_expense_pool p CROSS JOIN LATERAL jsonb_array_elements(p.allocations) line
WHERE NOT p.pending;

CREATE VIEW v_finance_sales_expense_client_facts AS
SELECT f.period,f.client_id,f.fee_key,SUM(f.amount_local) AS amount_local,
       bool_or(c.pending OR f.client_id IS NULL) AS pending
FROM v_finance_sales_expense_allocation_facts f JOIN v_finance_sales_expense_period_coverage c USING(period)
GROUP BY f.period,f.client_id,f.fee_key
UNION ALL
SELECT period,NULL::uuid,'FREIGHT',NULL::numeric,true
FROM v_finance_sales_expense_period_coverage WHERE pending;
SELECT fn_audit_track_table('finance_sales_expense_groups','COLUMN_SCOPED','data_change',false,ARRAY['id','period','employee_id','channel','sales_confirmed','reviewed','sort_order','request_fingerprint','updated_by'],true,NULL);
SELECT fn_audit_track_table('finance_sales_expense_assignments','COLUMN_SCOPED','data_change',false,ARRAY['entry_id','period','source_fingerprint','request_fingerprint','updated_by'],true,NULL);

-- Preserve any earlier statement-specific exceptions when excluding manufacturing/operating
-- analysis from the ordinary EXPENSE-only reference guard.
DO $guard$
DECLARE definition text; condition_start int; function_start int; condition text;
BEGIN
    SELECT pg_get_triggerdef(t.oid) INTO definition FROM pg_trigger t
    WHERE t.tgrelid='finance_report_line_bindings'::regclass AND t.tgname='trg_psref_report_binding_expense';
    condition_start:=strpos(definition,' WHEN ');function_start:=strpos(definition,' EXECUTE FUNCTION ');
    IF definition IS NULL OR condition_start=0 OR function_start<=condition_start THEN RAISE EXCEPTION 'expense binding guard anchor changed';END IF;
    condition:=substring(definition FROM condition_start+6 FOR function_start-condition_start-6);
    definition:=substring(definition FROM 1 FOR condition_start-1)||' WHEN ('||condition||
        ' AND NEW.line_key NOT LIKE ''MFG\_%'' AND NEW.line_key NOT LIKE ''OP\_%'')'||substring(definition FROM function_start);
    DROP TRIGGER trg_psref_report_binding_expense ON finance_report_line_bindings;
    EXECUTE definition;
END;
$guard$;
CREATE FUNCTION fn_guard_finance_analysis_cost_binding() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.line_key='MFG_LABOR_CONTROL' AND NOT EXISTS(
        SELECT 1 FROM finance_chart_code_styles m JOIN finance_chart_codes c ON c.code=m.code
        WHERE m.style_id=NEW.style_id AND c.code LIKE '410106%') THEN
        RAISE EXCEPTION '职工薪酬费来源须明确对应财务410106及细目' USING ERRCODE='23514';
    END IF;
    IF NOT fn_finance_cost_expense_style_allowed(NEW.style_id) THEN
        RAISE EXCEPTION '分析项目仅允许费用末级科目或已明确对应4101的制造成本末级科目' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_psref_report_binding_cost_analysis BEFORE INSERT OR UPDATE ON finance_report_line_bindings
    FOR EACH ROW WHEN (NEW.binding_kind='STYLE' AND (NEW.line_key LIKE 'MFG\_%' OR NEW.line_key LIKE 'OP\_%'))
    EXECUTE FUNCTION fn_guard_finance_analysis_cost_binding();
