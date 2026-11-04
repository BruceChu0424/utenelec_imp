-- Manufacturing cost accounts may receive FA/DA expense postings only through an explicit,
-- reviewed financial-chart relationship. Ordinary asset/control accounts remain ineligible.
CREATE FUNCTION fn_finance_cost_expense_style_allowed(p_style uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS(SELECT 1 FROM payment_styles s WHERE s.id=p_style AND NOT s.is_deleted
      AND NOT EXISTS(SELECT 1 FROM payment_styles child WHERE child.parent_id=s.id AND NOT child.is_deleted)
      AND (s.category='EXPENSE' OR (s.category='ACCOUNT' AND EXISTS(
          SELECT 1 FROM finance_chart_code_styles mapped JOIN finance_chart_codes chart ON chart.code=mapped.code
          WHERE mapped.style_id=s.id AND chart.code LIKE '4101%'))))
$$;

CREATE FUNCTION fn_guard_finance_asset_expense_reference()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE style uuid; previous uuid; require_active boolean:=COALESCE(TG_ARGV[1],'false')::boolean;
        force_check boolean:=COALESCE(TG_ARGV[2],'false')::boolean;
BEGIN
    style:=NULLIF(to_jsonb(NEW)->>TG_ARGV[0],'')::uuid;
    IF TG_OP='UPDATE' THEN previous:=NULLIF(to_jsonb(OLD)->>TG_ARGV[0],'')::uuid; END IF;
    IF style IS NULL OR (TG_OP='UPDATE' AND style IS NOT DISTINCT FROM previous AND NOT force_check) THEN RETURN NEW; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('PAYMENT_STYLE_HIERARCHY',0));
    IF NOT fn_finance_cost_expense_style_allowed(style) OR (require_active AND NOT EXISTS(
        SELECT 1 FROM payment_styles WHERE id=style AND status='使用')) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='资产费用科目须为费用末级或明确4101制造成本末级';
    END IF;
    RETURN NEW;
END $$;
DO $$ DECLARE spec record; BEGIN
    FOR spec IN SELECT * FROM (VALUES
       ('trg_psref_fixed_expense','fixed_assets','expense_style_id',true),
       ('trg_psref_fixed_exp_snap','fixed_assets','expense_style_snapshot_id',false),
       ('trg_psref_deferred_expense','deferred_expenses','expense_style_id',true),
       ('trg_psref_deferred_exp_snap','deferred_expenses','expense_style_snapshot_id',false),
       ('trg_psref_asset_cat_expense','finance_asset_categories','expense_style_id',false),
       ('trg_psref_asset_book_expense','finance_asset_books','expense_style_id',false),
       ('trg_psref_def_sched_expense','finance_deferral_schedule_versions','expense_style_id',false)
    ) AS rules(trigger_name,table_name,column_name,require_active) LOOP
       EXECUTE format('DROP TRIGGER %I ON %I',spec.trigger_name,spec.table_name);
       EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_asset_expense_reference(%L,%L)',
           spec.trigger_name,spec.table_name,spec.column_name,spec.require_active);
    END LOOP;
END $$;
DROP TRIGGER trg_psref_asset_cat_active_ins_expense_style_id ON finance_asset_categories;
DROP TRIGGER trg_psref_asset_cat_active_upd_expense_style_id ON finance_asset_categories;
CREATE TRIGGER trg_psref_asset_cat_active_ins_expense_style_id BEFORE INSERT ON finance_asset_categories
    FOR EACH ROW WHEN(NEW.status='ACTIVE') EXECUTE FUNCTION fn_guard_finance_asset_expense_reference('expense_style_id','true','true');
CREATE TRIGGER trg_psref_asset_cat_active_upd_expense_style_id BEFORE UPDATE OF status ON finance_asset_categories
    FOR EACH ROW WHEN(NEW.status='ACTIVE' AND OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION fn_guard_finance_asset_expense_reference('expense_style_id','true','true');

CREATE FUNCTION fn_guard_finance_asset_cost_chart_identity()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE style uuid; styles uuid[];
BEGIN
    IF TG_OP='INSERT' THEN styles:=ARRAY[NEW.style_id]; ELSIF TG_OP='DELETE' THEN styles:=ARRAY[OLD.style_id];
    ELSE styles:=ARRAY[OLD.style_id,NEW.style_id]; END IF;
    FOREACH style IN ARRAY styles LOOP
    IF EXISTS(SELECT 1 FROM payment_styles WHERE id=style AND category='ACCOUNT')
       AND NOT fn_finance_cost_expense_style_allowed(style)
       AND (EXISTS(SELECT 1 FROM finance_asset_categories WHERE expense_style_id=style AND NOT is_deleted)
         OR EXISTS(SELECT 1 FROM fixed_assets WHERE expense_style_snapshot_id=style AND NOT is_deleted)
         OR EXISTS(SELECT 1 FROM deferred_expenses WHERE expense_style_snapshot_id=style AND NOT is_deleted)
         OR EXISTS(SELECT 1 FROM finance_asset_books WHERE expense_style_id=style AND NOT is_deleted)
         OR EXISTS(SELECT 1 FROM finance_deferral_schedule_versions WHERE expense_style_id=style AND NOT is_deleted)) THEN
        RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='制造成本科目已被资产政策或冻结账簿引用，不能移除4101归属';
    END IF;
    END LOOP;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_finance_asset_cost_chart_identity AFTER INSERT OR UPDATE OR DELETE ON finance_chart_code_styles
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_asset_cost_chart_identity();

-- The former four-place column typmods must not round an exact source amount
-- before a CHECK can see it. Keep original facts and derived book values distinct.
DO $$ DECLARE targets jsonb; BEGIN
 SELECT jsonb_agg(jsonb_build_object('table',table_name,'column',column_name,'kind',amount_kind)) INTO targets FROM (VALUES
    ('fixed_assets','original_value','actual'),('fixed_assets','opening_accumulated_amount','book'),
    ('deferred_expenses','total_amount','actual'),
    ('finance_asset_books','original_value','actual'),('finance_asset_books','residual_amount','book'),
    ('finance_asset_books','depreciable_amount','book'),('finance_asset_books','accumulated_amount','book'),
    ('finance_asset_books','opening_accumulated_amount','book'),('finance_asset_books','net_book_value','book'),
    ('finance_deferral_schedule_versions','total_amount','actual'),
    ('finance_deferral_schedule_lines','opening_balance','book'),('finance_deferral_schedule_lines','amount','book'),
    ('finance_deferral_schedule_lines','accumulated_amount','book'),('finance_deferral_schedule_lines','closing_balance','book'),
    ('fa_depreciation_log','amount','book'),('fa_depreciation_log','opening_balance','book'),('fa_depreciation_log','accumulated_amount','book'),('fa_depreciation_log','closing_balance','book'),
    ('da_amortization_log','amount','book'),('da_amortization_log','opening_balance','book'),('da_amortization_log','accumulated_amount','book'),('da_amortization_log','closing_balance','book'),
    ('finance_asset_posting_lines','opening_balance','book'),('finance_asset_posting_lines','amount','book'),
    ('finance_asset_posting_lines','accumulated_amount','book'),('finance_asset_posting_lines','closing_balance','book'),
    ('finance_asset_posting_runs','total_amount','book'),
    ('finance_asset_posting_runs','reconciliation_difference','book'),('finance_asset_accounting_periods','reconciliation_difference','book')
 ) AS fields(table_name,column_name,amount_kind);
 PERFORM fn_migrate_financial_amount_columns(targets);
END $$;

-- Reuse installed validation bodies while removing their former local four-place casts.
DO $$ DECLARE target record;definition text; BEGIN
 FOR target IN SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.prokind='f' AND p.proname IN(
   'fn_validate_deferral_schedule_approval','fn_validate_finance_asset_run_posted','fn_validate_finance_asset_period_close') LOOP
  definition:=pg_get_functiondef(target.oid);
  definition:=regexp_replace(definition,'numeric\s*\(\s*18\s*,\s*4\s*\)','numeric','gi');
  EXECUTE definition;
 END LOOP;
END $$;

-- Preserve the already approved monthly installment of older corporate books.
-- New books write their exact shared-calculator result explicitly.
ALTER TABLE finance_asset_books ADD COLUMN regular_monthly_amount numeric CHECK(regular_monthly_amount IS NULL OR fn_financial_book_amount_is_exact(regular_monthly_amount));
-- A stored actual installment is a source fact. Never reconstruct an unrecorded
-- legacy monthly value by applying the retired four-decimal rounding policy.
UPDATE finance_asset_books book SET regular_monthly_amount=(
 SELECT log.amount FROM fa_depreciation_log log
 WHERE log.asset_book_id=book.id AND log.entry_kind='NORMAL' AND NOT log.is_deleted
 ORDER BY log.period,log.id LIMIT 1)
 WHERE book.method='STRAIGHT_LINE';
ALTER TABLE finance_deferral_schedule_versions ADD COLUMN nominal_monthly_amount numeric CHECK(nominal_monthly_amount IS NULL OR fn_financial_book_amount_is_exact(nominal_monthly_amount));
UPDATE finance_deferral_schedule_versions version SET nominal_monthly_amount=(
 SELECT line.amount FROM finance_deferral_schedule_lines line WHERE line.schedule_version_id=version.id
 ORDER BY line.sequence,line.id LIMIT 1)
 WHERE version.method='STRAIGHT_LINE' AND version.approved_at IS NOT NULL;

-- Signed immutable facts, including the original normal fact after a reversal. A posted
-- reversal is a separate negative event on its voucher date; current NORMAL status is not history.
CREATE VIEW v_finance_asset_posting_facts AS
SELECT 'FA'::text AS kind,l.id AS fact_id,l.asset_id AS object_id,
       COALESCE(p.expense_style_id,a.expense_style_snapshot_id,a.expense_style_id) AS expense_style_id,
       COALESCE(v.voucher_date,(to_date(l.period::text,'YYYY-MM')+interval '1 month'-interval '1 day')::date) AS business_date,
       to_char(COALESCE(v.voucher_date,(to_date(l.period::text,'YYYY-MM')+interval '1 month'-interval '1 day')::date),'YYYY-MM') AS period,
       l.period::text AS source_period,l.voucher_id,
       CASE l.entry_kind WHEN 'NORMAL' THEN l.amount ELSE -l.amount END AS amount_local,
       (v.id IS NULL OR v.is_deleted OR NOT fn_finance_gl_voucher_is_booked(v.id) OR p.id IS NULL OR r.id IS NULL OR r.is_deleted OR b.id IS NULL
          OR b.book_type<>'CORPORATE' OR r.book_type<>'CORPORATE' OR p.is_deleted
          OR p.run_id IS DISTINCT FROM r.id OR p.fixed_asset_id IS DISTINCT FROM a.id
          OR p.asset_book_id IS DISTINCT FROM b.id OR p.voucher_id IS DISTINCT FROM v.id
          OR r.voucher_id IS DISTINCT FROM v.id OR p.line_kind IS DISTINCT FROM l.entry_kind
          OR p.amount IS DISTINCT FROM l.amount OR r.status NOT IN('POSTED','REVERSED')
          OR COALESCE(p.expense_style_id,a.expense_style_snapshot_id,a.expense_style_id) IS NULL) AS pending
FROM fa_depreciation_log l JOIN fixed_assets a ON a.id=l.asset_id
LEFT JOIN gl_vouchers v ON v.id=l.voucher_id
LEFT JOIN finance_asset_posting_lines p ON p.id=l.posting_line_id
LEFT JOIN finance_asset_posting_runs r ON r.id=l.posting_run_id
LEFT JOIN finance_asset_books b ON b.id=l.asset_book_id
WHERE NOT l.is_deleted AND l.entry_kind IN('NORMAL','REVERSAL')
  AND (l.entry_kind='NORMAL' AND l.status IN('ACTIVE','REVERSED') OR l.entry_kind='REVERSAL' AND l.status='ACTIVE')
  AND COALESCE(r.book_type,b.book_type,'CORPORATE')='CORPORATE'
UNION ALL
SELECT 'DA',l.id,l.deferred_id,COALESCE(p.expense_style_id,a.expense_style_snapshot_id,a.expense_style_id),
       COALESCE(v.voucher_date,(to_date(l.period::text,'YYYY-MM')+interval '1 month'-interval '1 day')::date),
       to_char(COALESCE(v.voucher_date,(to_date(l.period::text,'YYYY-MM')+interval '1 month'-interval '1 day')::date),'YYYY-MM'),
       l.period::text,l.voucher_id,CASE l.entry_kind WHEN 'NORMAL' THEN l.amount ELSE -l.amount END,
       (v.id IS NULL OR v.is_deleted OR NOT fn_finance_gl_voucher_is_booked(v.id) OR p.id IS NULL OR r.id IS NULL OR r.is_deleted OR r.book_type<>'CORPORATE'
          OR p.is_deleted OR p.run_id IS DISTINCT FROM r.id OR p.deferred_expense_id IS DISTINCT FROM a.id
          OR p.voucher_id IS DISTINCT FROM v.id OR r.voucher_id IS DISTINCT FROM v.id
          OR p.line_kind IS DISTINCT FROM l.entry_kind OR p.amount IS DISTINCT FROM l.amount OR r.status NOT IN('POSTED','REVERSED')
          OR COALESCE(p.expense_style_id,a.expense_style_snapshot_id,a.expense_style_id) IS NULL)
FROM da_amortization_log l JOIN deferred_expenses a ON a.id=l.deferred_id
LEFT JOIN gl_vouchers v ON v.id=l.voucher_id
LEFT JOIN finance_asset_posting_lines p ON p.id=l.posting_line_id
LEFT JOIN finance_asset_posting_runs r ON r.id=l.posting_run_id
WHERE NOT l.is_deleted AND l.entry_kind IN('NORMAL','REVERSAL')
  AND (l.entry_kind='NORMAL' AND l.status IN('ACTIVE','REVERSED') OR l.entry_kind='REVERSAL' AND l.status='ACTIVE')
  AND COALESCE(r.book_type,'CORPORATE')='CORPORATE';

CREATE TABLE finance_asset_template_metadata (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),object_type text NOT NULL CHECK(object_type IN('FIXED_ASSET','DEFERRED_EXPENSE')),
    object_id uuid NOT NULL,valid_from date NOT NULL,
    party_name text NOT NULL DEFAULT '' CHECK(length(party_name)<=240),
    unit_specification text NOT NULL DEFAULT '' CHECK(length(unit_specification)<=100),
    location_caption text NOT NULL DEFAULT '' CHECK(length(location_caption)<=300),
    category_caption text NOT NULL DEFAULT '' CHECK(length(category_caption)<=200),
    usage_caption text NOT NULL DEFAULT '' CHECK(length(usage_caption)<=200),
    source_month text NOT NULL DEFAULT '' CHECK(length(source_month)<=80),
    document_date date,first_level_caption text NOT NULL DEFAULT '' CHECK(length(first_level_caption)<=240),
    second_level_caption text NOT NULL DEFAULT '' CHECK(length(second_level_caption)<=240),
    acceptance_caption text NOT NULL DEFAULT '' CHECK(length(acceptance_caption)<=100),
    confirmed boolean NOT NULL DEFAULT false,source_reference text NOT NULL CHECK(length(btrim(source_reference)) BETWEEN 1 AND 1000),
    row_version bigint NOT NULL DEFAULT 0,created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid NOT NULL REFERENCES users(id),updated_by uuid NOT NULL REFERENCES users(id),
    UNIQUE(object_type,object_id,valid_from)
);
CREATE INDEX idx_finance_asset_template_metadata_lookup ON finance_asset_template_metadata(object_type,object_id,valid_from DESC);
CREATE TRIGGER trg_audit_finance_asset_template_metadata AFTER INSERT OR UPDATE OR DELETE ON finance_asset_template_metadata
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE finance_asset_template_metadata ENABLE ALWAYS TRIGGER trg_audit_finance_asset_template_metadata;

CREATE TABLE finance_asset_template_operations (
    request_id uuid PRIMARY KEY,actor_id uuid NOT NULL REFERENCES users(id),fingerprint text NOT NULL CHECK(fingerprint ~ '^[0-9a-f]{64}$'),
    result jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);

-- External source history is subledger evidence only: it never inserts GL entries.
CREATE TABLE finance_asset_opening_groups (
    id uuid PRIMARY KEY,actor_id uuid NOT NULL REFERENCES users(id),source_import_id uuid NOT NULL REFERENCES finance_template_sources(id),
    source_voucher_id uuid REFERENCES gl_vouchers(id),as_of date NOT NULL,
    source_voucher_ids uuid[] NOT NULL DEFAULT '{}',zero_balance_evidence jsonb NOT NULL DEFAULT '[]',
    fingerprint text NOT NULL CHECK(fingerprint ~ '^[0-9a-f]{64}$'),
    status text NOT NULL CHECK(status IN('SUBMITTED','APPROVED','REVOKE_PENDING','REVOKED')),
    source_entry_snapshot jsonb NOT NULL,member_snapshot jsonb NOT NULL,reason text NOT NULL,
    approved_by uuid REFERENCES users(id),approved_at timestamptz,
    revoke_actor_id uuid REFERENCES users(id),revoke_reason text,revoke_approved_by uuid REFERENCES users(id),revoked_at timestamptz,
    row_version bigint NOT NULL DEFAULT 0,created_at timestamptz NOT NULL DEFAULT now(),
    CHECK(approved_by IS NULL OR approved_by<>actor_id),
    CHECK(revoke_approved_by IS NULL OR revoke_approved_by<>revoke_actor_id)
);
CREATE TABLE finance_asset_opening_members (
    group_id uuid NOT NULL REFERENCES finance_asset_opening_groups(id),object_type text NOT NULL CHECK(object_type IN('FIXED_ASSET','DEFERRED_EXPENSE')),
    object_id uuid NOT NULL,source_row integer NOT NULL CHECK(source_row>0),
    source_sha256 text NOT NULL,source_sheet text NOT NULL,
    original_amount numeric NOT NULL CHECK(original_amount>0 AND fn_financial_amount_is_exact(original_amount)),accumulated_amount numeric NOT NULL CHECK(accumulated_amount>=0 AND fn_financial_book_amount_is_exact(accumulated_amount)),
    remaining_months integer NOT NULL CHECK(remaining_months BETWEEN 0 AND 1200),
    nominal_monthly_amount numeric NOT NULL CHECK(nominal_monthly_amount>=0 AND fn_financial_book_amount_is_exact(nominal_monthly_amount)),
    cost_style_id uuid NOT NULL REFERENCES payment_styles(id),accumulated_style_id uuid REFERENCES payment_styles(id),
    active boolean NOT NULL DEFAULT true,PRIMARY KEY(group_id,object_type,object_id),UNIQUE(group_id,source_row),
    CHECK(accumulated_amount<=original_amount)
);
CREATE UNIQUE INDEX ux_finance_asset_opening_live_member ON finance_asset_opening_members(object_type,object_id) WHERE active;
CREATE UNIQUE INDEX ux_finance_asset_opening_live_source_row ON finance_asset_opening_members(source_sha256,source_sheet,source_row) WHERE active;
CREATE TABLE finance_asset_opening_entry_claims (
    entry_id uuid PRIMARY KEY REFERENCES gl_entries(id),group_id uuid NOT NULL REFERENCES finance_asset_opening_groups(id)
);
CREATE TABLE finance_asset_template_history (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),group_id uuid NOT NULL REFERENCES finance_asset_opening_groups(id),
    object_type text NOT NULL CHECK(object_type IN('FIXED_ASSET','DEFERRED_EXPENSE')),object_id uuid NOT NULL,
    period_from char(7),period_to char(7) NOT NULL,
    amount_local numeric NOT NULL CHECK(fn_financial_book_amount_is_exact(amount_local)),reported_value text NOT NULL,
    source_import_id uuid NOT NULL REFERENCES finance_template_sources(id),source_row integer NOT NULL,source_column integer NOT NULL,
    adjustment_reason text NOT NULL DEFAULT '',UNIQUE(group_id,object_type,object_id,source_row,source_column),
    CHECK(period_from IS NULL OR period_from<=period_to)
);
CREATE INDEX idx_finance_asset_template_history_object ON finance_asset_template_history(object_type,object_id,period_to);
ALTER TABLE deferred_expenses ADD COLUMN opening_as_of date,
    ADD COLUMN opening_amortized_amount numeric NOT NULL DEFAULT 0 CHECK(opening_amortized_amount>=0 AND fn_financial_book_amount_is_exact(opening_amortized_amount)),
    ADD COLUMN opening_remaining_months integer CHECK(opening_remaining_months BETWEEN 0 AND 1200);
ALTER TABLE finance_deferral_schedule_versions ADD COLUMN opening_amortized_amount numeric NOT NULL DEFAULT 0 CHECK(opening_amortized_amount>=0 AND fn_financial_book_amount_is_exact(opening_amortized_amount));
ALTER TABLE deferred_expenses ADD CONSTRAINT deferred_opening_shape CHECK(
    (opening_as_of IS NULL AND opening_amortized_amount=0 AND opening_remaining_months IS NULL)
    OR (opening_as_of IS NOT NULL AND opening_amortized_amount<=total_amount AND opening_remaining_months BETWEEN 0 AND 1200));
ALTER TABLE finance_deferral_schedule_versions ADD CONSTRAINT deferred_schedule_opening_amount CHECK(opening_amortized_amount<=total_amount);
ALTER TABLE finance_deferral_schedule_versions DROP CONSTRAINT finance_deferral_versions_months_chk;
ALTER TABLE finance_deferral_schedule_versions ADD CONSTRAINT finance_deferral_versions_months_chk CHECK(
    useful_months BETWEEN 1 AND 1200 OR (useful_months=0 AND opening_amortized_amount=total_amount));
DO $$ DECLARE definition text; BEGIN
    SELECT pg_get_functiondef('fn_validate_deferral_schedule_approval()'::regprocedure) INTO definition;
    IF strpos(definition,'v_amount <> NEW.total_amount')=0 OR strpos(definition,'v_previous_closing := NEW.total_amount;')=0 THEN
        RAISE EXCEPTION 'deferred schedule approval validation anchor changed';
    END IF;
    definition:=replace(definition,'v_amount <> NEW.total_amount','v_amount + NEW.opening_amortized_amount <> NEW.total_amount');
    definition:=replace(definition,'OR v_first_period <> NEW.start_period','OR (v_line_count>0 AND v_first_period <> NEW.start_period)');
    definition:=replace(definition,'OR v_last_period <> NEW.end_period','OR (v_line_count>0 AND v_last_period <> NEW.end_period)');
    definition:=replace(definition,'v_previous_closing := NEW.total_amount;',
        'v_previous_closing := NEW.total_amount-NEW.opening_amortized_amount; v_running_amount := NEW.opening_amortized_amount;');
    EXECUTE definition;
END $$;
CREATE TRIGGER trg_audit_finance_asset_opening_groups AFTER INSERT OR UPDATE OR DELETE ON finance_asset_opening_groups FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_asset_opening_members AFTER INSERT OR UPDATE OR DELETE ON finance_asset_opening_members FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_asset_template_history AFTER INSERT OR UPDATE OR DELETE ON finance_asset_template_history FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE finance_asset_opening_groups ENABLE ALWAYS TRIGGER trg_audit_finance_asset_opening_groups;
ALTER TABLE finance_asset_opening_members ENABLE ALWAYS TRIGGER trg_audit_finance_asset_opening_members;
ALTER TABLE finance_asset_template_history ENABLE ALWAYS TRIGGER trg_audit_finance_asset_template_history;

CREATE FUNCTION fn_finance_asset_opening_group_valid(p_id uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
 WITH actual_members AS (
   SELECT m.*,a.original_value AS actual_original,a.opening_accumulated_amount AS actual_accumulated,
      a.opening_remaining_months AS actual_remaining,a.opening_as_of AS actual_date,
      COALESCE(a.cost_style_snapshot_id,c.cost_style_id) AS actual_cost,
      COALESCE(a.accumulated_style_snapshot_id,c.accumulated_style_id) AS actual_credit,a.is_deleted,a.name AS actual_name,a.source_id,a.source_type,a.source_line_ref
   FROM finance_asset_opening_members m JOIN fixed_assets a ON a.id=m.object_id
   LEFT JOIN finance_asset_categories c ON c.id=a.category_id WHERE m.group_id=p_id AND m.active AND m.object_type='FIXED_ASSET'
   UNION ALL
   SELECT m.*,a.total_amount,a.opening_amortized_amount,a.opening_remaining_months,a.opening_as_of,
      COALESCE(a.cost_style_snapshot_id,c.cost_style_id),NULL::uuid,a.is_deleted,a.name,a.source_id,a.source_type,a.source_line_ref
   FROM finance_asset_opening_members m JOIN deferred_expenses a ON a.id=m.object_id
   LEFT JOIN finance_asset_categories c ON c.id=a.category_id WHERE m.group_id=p_id AND m.active AND m.object_type='DEFERRED_EXPENSE'
 )
 SELECT EXISTS(SELECT 1 FROM finance_asset_opening_groups g LEFT JOIN gl_vouchers v ON v.id=g.source_voucher_id
   WHERE g.id=p_id AND g.status IN('SUBMITTED','APPROVED')
   AND ((v.status=1 AND NOT v.is_deleted AND v.voucher_date<=g.as_of)
       OR (g.source_voucher_id IS NULL AND jsonb_array_length(g.source_entry_snapshot)=0 AND jsonb_array_length(g.zero_balance_evidence)>0))
   AND (jsonb_array_length(g.source_entry_snapshot)>0 OR jsonb_array_length(g.zero_balance_evidence)>0)
   AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(g.zero_balance_evidence) proof
       WHERE NOT EXISTS(SELECT 1 FROM finance_asset_opening_members m WHERE m.group_id=g.id AND m.active
            AND m.object_type='DEFERRED_EXPENSE' AND m.cost_style_id=(proof->>'styleId')::uuid
            AND m.original_amount=m.accumulated_amount AND m.remaining_months=0)
         OR fn_finance_style_balance_asof((proof->>'styleId')::uuid,g.as_of) IS DISTINCT FROM 0::numeric
         OR fn_finance_style_balance_evidence_fingerprint((proof->>'styleId')::uuid,g.as_of) IS DISTINCT FROM proof->>'fingerprint'
         OR proof->>'fingerprint' IS NULL OR proof->>'asOf' IS DISTINCT FROM g.as_of::text)
   AND NOT EXISTS(SELECT 1 FROM unnest(g.source_voucher_ids) source_id LEFT JOIN gl_vouchers source ON source.id=source_id
       WHERE source.id IS NULL OR source.is_deleted OR source.status<>1 OR source.voucher_date>g.as_of)
   AND (SELECT count(*) FROM actual_members)=(SELECT count(*) FROM finance_asset_opening_members WHERE group_id=p_id AND active)
   AND NOT EXISTS(SELECT 1 FROM actual_members a WHERE a.is_deleted OR a.actual_original IS DISTINCT FROM a.original_amount
       OR a.actual_accumulated IS DISTINCT FROM a.accumulated_amount OR a.actual_remaining IS DISTINCT FROM a.remaining_months
       OR a.actual_date IS DISTINCT FROM g.as_of OR a.actual_cost IS DISTINCT FROM a.cost_style_id
       OR a.actual_credit IS DISTINCT FROM a.accumulated_style_id OR a.source_id IS DISTINCT FROM g.source_import_id
       OR a.source_type IS DISTINCT FROM 'FINANCE_TEMPLATE' OR a.source_line_ref IS DISTINCT FROM 'ROW:'||a.source_row::text
       OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(g.member_snapshot) snap
          WHERE (snap->>'objectId')::uuid=a.object_id AND snap->>'objectType'=a.object_type AND snap->>'name'=a.actual_name))
   AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(g.source_entry_snapshot) snap
     LEFT JOIN gl_entries e ON e.id=(snap->>'id')::uuid
     LEFT JOIN finance_asset_opening_entry_claims claim ON claim.entry_id=e.id AND claim.group_id=g.id
     WHERE e.id IS NULL OR e.is_deleted OR e.voucher_id IS DISTINCT FROM (snap->>'voucherId')::uuid OR claim.entry_id IS NULL
       OR e.style_id IS DISTINCT FROM (snap->>'styleId')::uuid OR e.direction IS DISTINCT FROM (snap->>'direction')::integer
       OR e.amount IS DISTINCT FROM (snap->>'amount')::numeric))
$$;
CREATE FUNCTION fn_guard_finance_asset_opening_posting() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE p_kind text; p_object_id uuid;
BEGIN
 IF NEW.entry_kind<>'NORMAL' THEN RETURN NEW;END IF;
 IF TG_TABLE_NAME='fa_depreciation_log' THEN p_kind:='FIXED_ASSET';p_object_id:=NEW.asset_id;
 ELSE p_kind:='DEFERRED_EXPENSE';p_object_id:=NEW.deferred_id;END IF;
 PERFORM 1 FROM finance_asset_opening_members m JOIN finance_asset_opening_groups g ON g.id=m.group_id
    WHERE m.object_type=p_kind AND m.object_id=p_object_id AND m.active FOR SHARE OF g;
 IF EXISTS(SELECT 1 FROM finance_asset_opening_members m JOIN finance_asset_opening_groups g ON g.id=m.group_id
    WHERE m.object_type=p_kind AND m.object_id=p_object_id AND m.active
      AND (g.status<>'APPROVED' OR NOT fn_finance_asset_opening_group_valid(g.id))) THEN
    RAISE EXCEPTION '本组接续正在核对/撤销或来源已变化，不能新增计提' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_finance_asset_opening_fa_post BEFORE INSERT ON fa_depreciation_log FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_asset_opening_posting();
CREATE TRIGGER trg_finance_asset_opening_da_post BEFORE INSERT ON da_amortization_log FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_asset_opening_posting();
CREATE FUNCTION fn_guard_finance_asset_opening_gl() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE vouchers uuid[];
BEGIN
 IF TG_TABLE_NAME='gl_vouchers' THEN
    IF TG_OP='INSERT' THEN RETURN NEW;END IF;vouchers:=ARRAY[OLD.id];
 ELSIF TG_OP='INSERT' THEN vouchers:=ARRAY[NEW.voucher_id];
 ELSIF TG_OP='DELETE' THEN vouchers:=ARRAY[OLD.voucher_id];
 ELSE vouchers:=ARRAY[OLD.voucher_id,NEW.voucher_id];END IF;
 IF EXISTS(SELECT 1 FROM finance_asset_opening_entry_claims claim JOIN gl_entries entry ON entry.id=claim.entry_id
    WHERE entry.voucher_id=ANY(vouchers)) THEN
    RAISE EXCEPTION '来源凭证已被整组期初接续认领，请先经另一人复核撤销接续后再更正原GL' USING ERRCODE='23514';
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD;END IF;RETURN NEW;
END $$;
CREATE TRIGGER trg_finance_asset_opening_gl_voucher BEFORE UPDATE OR DELETE ON gl_vouchers FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_asset_opening_gl();
CREATE TRIGGER trg_finance_asset_opening_gl_entry BEFORE INSERT OR UPDATE OR DELETE ON gl_entries FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_asset_opening_gl();
CREATE VIEW v_finance_asset_report_facts AS
WITH valid_groups AS MATERIALIZED (SELECT g.id,g.status,fn_finance_asset_opening_group_valid(g.id) AS valid
    FROM finance_asset_opening_groups g WHERE g.status<>'REVOKED')
SELECT kind,object_id,fact_id,period::char(7) AS period_from,period::char(7) AS period_to,
    business_date AS fact_date,amount_local,pending,'POSTING'::text AS fact_kind
FROM v_finance_asset_posting_facts
UNION ALL
SELECT CASE h.object_type WHEN 'FIXED_ASSET' THEN 'FA' ELSE 'DA' END,h.object_id,h.id,h.period_from,h.period_to,
    (to_date(h.period_to::text,'YYYY-MM')+interval '1 month'-interval '1 day')::date,h.amount_local,
    (g.status<>'APPROVED' OR NOT g.valid),'HISTORY'
FROM finance_asset_template_history h JOIN valid_groups g ON g.id=h.group_id
JOIN finance_asset_opening_members m ON m.group_id=h.group_id AND m.object_type=h.object_type AND m.object_id=h.object_id
WHERE m.active AND g.status<>'REVOKED';
SELECT fn_audit_track_table('finance_asset_template_metadata','FULL','data_change',false,NULL,true,NULL);
SELECT fn_audit_track_table('finance_asset_opening_groups','FULL','data_change',false,NULL,true,NULL);
SELECT fn_audit_track_table('finance_asset_opening_members','FULL','data_change',false,NULL,true,NULL);
SELECT fn_audit_track_table('finance_asset_opening_entry_claims','FULL','data_change',false,NULL,true,NULL);
SELECT fn_audit_track_table('finance_asset_template_history','FULL','data_change',false,NULL,true,NULL);
CREATE TRIGGER trg_finance_asset_template_history_immutable BEFORE UPDATE OR DELETE ON finance_asset_template_history
    FOR EACH ROW EXECUTE FUNCTION fn_reject_update_or_delete();
CREATE FUNCTION fn_guard_finance_asset_opening_group() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='UPDATE' AND NEW.row_version=OLD.row_version+1
    AND ((OLD.status='SUBMITTED' AND NEW.status='APPROVED')
      OR (OLD.status IN('SUBMITTED','APPROVED') AND NEW.status='REVOKE_PENDING')
      OR (OLD.status='REVOKE_PENDING' AND NEW.status='REVOKED'))
    AND (to_jsonb(NEW)-ARRAY['status','row_version','approved_by','approved_at','revoke_actor_id','revoke_reason','revoke_approved_by','revoked_at'])
       =(to_jsonb(OLD)-ARRAY['status','row_version','approved_by','approved_at','revoke_actor_id','revoke_reason','revoke_approved_by','revoked_at']) THEN RETURN NEW;END IF;
 RAISE EXCEPTION '接续组原始快照须永久保留，只能按复核/撤销流程追加状态' USING ERRCODE='55000';
END $$;
CREATE TRIGGER trg_finance_asset_opening_group_immutable BEFORE UPDATE OR DELETE ON finance_asset_opening_groups
    FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_asset_opening_group();


-- Frozen older books retain their approved residual. New draft validation uses
-- the shared exact calculator, while the row itself cannot exceed gross cost.
ALTER TABLE fixed_assets DROP CONSTRAINT fixed_asset_opening_shape;
ALTER TABLE fixed_assets ADD CONSTRAINT fixed_asset_opening_shape CHECK(
    (opening_as_of IS NULL AND opening_accumulated_amount=0 AND opening_remaining_months IS NULL AND opening_voucher_id IS NULL)
    OR (opening_as_of IS NOT NULL AND opening_remaining_months BETWEEN 0 AND 1200 AND opening_accumulated_amount BETWEEN 0 AND original_value));
