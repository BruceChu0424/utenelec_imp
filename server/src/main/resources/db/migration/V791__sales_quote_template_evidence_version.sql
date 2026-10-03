-- Pin each adoption to the immutable version the user actually reviewed.
-- Older same-layout evidence did not record a version; do not infer one from today's template.
ALTER TABLE sales_quote_template_evidence
    ADD COLUMN confirmed_column_roles jsonb CHECK (confirmed_column_roles IS NULL OR jsonb_typeof(confirmed_column_roles)='object'),
    ADD COLUMN template_version integer CHECK (template_version > 0),
    ADD CONSTRAINT fk_sales_quote_template_evidence_version
        FOREIGN KEY (template_id, template_version)
        REFERENCES sales_quote_template_versions(template_id, version);

WITH attributable AS (
    SELECT e.job_id, min(v.version) AS version
    FROM sales_quote_template_evidence e
    JOIN sales_quote_template_versions v ON v.template_id=e.template_id AND v.source_job_id=e.job_id
    GROUP BY e.job_id HAVING count(*)=1
)
UPDATE sales_quote_template_evidence e SET template_version=a.version
FROM attributable a WHERE e.job_id=a.job_id;

COMMENT ON COLUMN sales_quote_template_evidence.template_version IS
    'Immutable version adopted by this job; null means legacy evidence cannot prove an exact version';

CREATE FUNCTION fn_guard_quote_template_evidence_version() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF OLD.template_version IS NOT NULL AND NEW.template_version IS DISTINCT FROM OLD.template_version THEN
        RAISE EXCEPTION '已采用的报价模板版本不可改写' USING ERRCODE='23514';
    END IF;
    IF OLD.confirmed_column_roles IS NOT NULL AND NEW.confirmed_column_roles IS DISTINCT FROM OLD.confirmed_column_roles THEN
        RAISE EXCEPTION '已采用的报价模板字段映射不可改写' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_quote_template_evidence_version
BEFORE UPDATE OF template_version, confirmed_column_roles ON sales_quote_template_evidence
FOR EACH ROW EXECUTE FUNCTION fn_guard_quote_template_evidence_version();
ALTER TABLE sales_quote_template_evidence ENABLE ALWAYS TRIGGER trg_quote_template_evidence_version;
