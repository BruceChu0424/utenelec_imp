-- Preserve original M_Style.ItemID separately from the V277 live UUID shadow.
ALTER TABLE public.payment_styles
    ADD COLUMN legacy_source_code text,
    ADD COLUMN legacy_source_item_id integer,
    ADD COLUMN legacy_source_import_run_id uuid REFERENCES public.legacy_migration_runs(run_id),
    ADD CONSTRAINT payment_styles_legacy_source_item_requires_run
        CHECK (legacy_source_import_run_id IS NOT NULL OR
               (legacy_source_code IS NULL AND legacy_source_item_id IS NULL));

COMMENT ON COLUMN public.payment_styles.legacy_source_code IS
    'Read-only original typed M_Style.StyleNumber. Source semantics only, not the current SK display code; inspect source run, category and true ancestry together.';

COMMENT ON COLUMN public.payment_styles.legacy_source_item_id IS
    'Original typed M_Style.ItemID; preserves NULL/0/raw integer for review. Historical source only, never current account authority.';
COMMENT ON COLUMN public.payment_styles.legacy_source_import_run_id IS
    'PRESERVE source run for the original M_Style row; complete typed row/file/rowSHA and pending reason are recorded late in the run source evidence.';
COMMENT ON COLUMN public.payment_styles.linked_account_legacy_id IS
    'Current accounts UUID legacy shadow only; requires linked_account_id and the same live account identity. Unresolved original ItemID belongs in legacy_source_item_id.';

CREATE FUNCTION public.fn_guard_payment_style_legacy_source_reference() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE mapping text;
BEGIN
    IF TG_OP='UPDATE' AND
       (NEW.legacy_source_code,NEW.legacy_source_item_id,NEW.legacy_source_import_run_id)
       IS NOT DISTINCT FROM (OLD.legacy_source_code,OLD.legacy_source_item_id,OLD.legacy_source_import_run_id) THEN
        RETURN NEW;
    END IF;
    IF TG_OP='INSERT' AND NEW.legacy_source_code IS NULL AND NEW.legacy_source_item_id IS NULL
       AND NEW.legacy_source_import_run_id IS NULL THEN
        RETURN NEW; -- Ordinary current master creation has no legacy source.
    END IF;
    IF NEW.legacy_source_import_run_id IS NULL OR NEW.legacy_id IS NULL OR NEW.legacy_id<=0 THEN
        RAISE EXCEPTION 'fund-classification source reference requires its positive legacy identity and source run'
            USING ERRCODE='23514';
    END IF;
    PERFORM public.fn_require_legacy_bootstrap(NEW.legacy_source_import_run_id,'m_style.csv');
    PERFORM public.fn_require_legacy_bootstrap(NEW.legacy_source_import_run_id,'m_acc.csv');
    SELECT mapping_version INTO mapping FROM public.legacy_migration_runs
        WHERE run_id=NEW.legacy_source_import_run_id;
    IF mapping !~ '^bootstrap-v[1-9][0-9]*$' OR substring(mapping FROM 12)::integer<18 THEN
        RAISE EXCEPTION 'fund-classification source reference requires bootstrap protocol 18 or newer'
            USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_payment_style_legacy_source_reference
    BEFORE INSERT OR UPDATE OF legacy_source_code,legacy_source_item_id,legacy_source_import_run_id
    ON public.payment_styles FOR EACH ROW
    EXECUTE FUNCTION public.fn_guard_payment_style_legacy_source_reference();

-- No V277 function, current linked-account CHECK/FK, account status, financial
-- value, approval, master-code reservation, or reset-policy entry is weakened.

-- Historical report semantics are qualified by original root identity and a
-- complete successful source run, never by a mutable/current display code.
-- Call from a MATERIALIZED root inventory, not once per financial entry.
CREATE FUNCTION public.fn_legacy_payment_style_source_root_matches(
    p_style_id uuid,p_category text,p_source_code text) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,public,pg_temp AS $$
WITH source AS MATERIALIZED (
 SELECT style.*,run.status run_status,run.reconciliation_status,run.mapping_version,
        run.target run_target,run.migration_mode,
        run.export_manifest_sha256,run.migration_repository_commit,
        run.reconciliation_summary->'financeMasterSources' evidence,
        file.sha256 file_sha256
 FROM public.payment_styles style
 JOIN public.legacy_migration_runs run ON run.run_id=style.legacy_source_import_run_id
 JOIN public.legacy_migration_run_files file
   ON file.run_id=run.run_id AND file.file_name='m_style.csv'
 WHERE style.id=p_style_id AND style.parent_id IS NULL AND style.category=p_category
   AND btrim(style.legacy_source_code)=p_source_code
), selected AS MATERIALIZED (
 SELECT source.*,evidence->'styles'->legacy_id::text entry FROM source
)
SELECT coalesce(bool_and(
 run_status='SUCCESS' AND reconciliation_status='PASSED'
 AND run_target='--bootstrap-all' AND migration_mode='BOOTSTRAP'
 AND CASE WHEN mapping_version ~ '^bootstrap-v[1-9][0-9]*$'
          THEN substring(mapping_version FROM 12)::numeric>=18 ELSE false END
 AND evidence->>'format'='finance-master-sources-v1'
 AND evidence->>'run_id'=legacy_source_import_run_id::text
 AND evidence->>'manifest_sha256'=export_manifest_sha256::text
 AND evidence->>'frozen_commit'=migration_repository_commit
 AND evidence->>'style_file_sha256'=file_sha256::text
 AND entry->>'target_id'=id::text
 AND entry->'typed_source'->>'legacy_id'=legacy_id::text
 AND entry->'typed_source'->>'code' IS NOT DISTINCT FROM legacy_source_code
 AND entry->'typed_source'->>'item_id' IS NOT DISTINCT FROM legacy_source_item_id::text
 AND coalesce((entry->'typed_source'->>'parent_legacy')::integer,0)=0
 AND CASE (entry->'typed_source'->>'style_class_id')::integer
     WHEN 1 THEN 'ACCOUNT' WHEN 2 THEN 'LIABILITY' WHEN 3 THEN 'EQUITY'
     WHEN 4 THEN 'EXPENSE' WHEN 5 THEN 'INCOME' ELSE 'METHOD' END=p_category
 AND entry->>'source_row_sha256'=encode(digest((entry->'typed_source')::text,'sha256'),'hex')
 AND (SELECT count(*) FROM jsonb_each(evidence->'styles') candidate
      WHERE btrim(candidate.value->'typed_source'->>'code')=p_source_code
        AND coalesce((candidate.value->'typed_source'->>'parent_legacy')::integer,0)=0
        AND CASE (candidate.value->'typed_source'->>'style_class_id')::integer
            WHEN 1 THEN 'ACCOUNT' WHEN 2 THEN 'LIABILITY' WHEN 3 THEN 'EQUITY'
            WHEN 4 THEN 'EXPENSE' WHEN 5 THEN 'INCOME' ELSE 'METHOD' END=p_category)=1
),false) FROM selected;
$$;
COMMENT ON FUNCTION public.fn_legacy_payment_style_source_root_matches(uuid,text,text) IS
    'Read-only report source-root identity: successful source run + complete original row SHA + exact current root UUID/category; current SK code and ordinary same-code modern roots are never semantic identities.';
