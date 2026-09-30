-- Sanitized presentation only: original uploaded files and customer values are never template payloads.
CREATE TABLE sales_quote_template_candidates (
    job_id uuid PRIMARY KEY REFERENCES ai_jobs(id) ON DELETE CASCADE,
    actor_user_id uuid NOT NULL REFERENCES users(id),
    source_name varchar(255) NOT NULL,
    fingerprint varchar(64) NOT NULL CHECK (fingerprint ~ '^[0-9a-f]{64}$'),
    workbook_bytes bytea NOT NULL CHECK (octet_length(workbook_bytes) <= 15728640),
    mapping jsonb NOT NULL,
    features jsonb NOT NULL,
    expires_at timestamptz NOT NULL DEFAULT now() + interval '7 days',
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE sales_quote_customer_templates (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id uuid NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
    name varchar(100) NOT NULL,
    fingerprint varchar(64) NOT NULL CHECK (fingerprint ~ '^[0-9a-f]{64}$'),
    features jsonb NOT NULL,
    current_version int NOT NULL DEFAULT 1 CHECK (current_version > 0),
    use_count int NOT NULL DEFAULT 1 CHECK (use_count > 0),
    last_used_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (client_id, fingerprint)
);
CREATE TABLE sales_quote_template_versions (
    template_id uuid NOT NULL REFERENCES sales_quote_customer_templates(id) ON DELETE CASCADE,
    version int NOT NULL CHECK (version > 0),
    source_name varchar(255) NOT NULL,
    source_job_id uuid,
    workbook_bytes bytea NOT NULL CHECK (octet_length(workbook_bytes) <= 15728640),
    mapping jsonb NOT NULL,
    payload_sha256 varchar(64) NOT NULL,
    captured_by uuid NOT NULL REFERENCES users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (template_id, version)
);
CREATE TABLE sales_quote_template_evidence (
    job_id uuid PRIMARY KEY,
    template_id uuid NOT NULL REFERENCES sales_quote_customer_templates(id) ON DELETE CASCADE,
    client_id uuid NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
    doc_type varchar(16) NOT NULL CHECK (doc_type IN ('quote','order')),
    doc_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_sales_quote_templates_client ON sales_quote_customer_templates(client_id, last_used_at DESC);
CREATE INDEX idx_sales_quote_template_candidates_expiry ON sales_quote_template_candidates(expires_at);
COMMENT ON TABLE sales_quote_template_candidates IS 'AI task staging: sanitized spreadsheet presentation, purged after use/failure/expiry';
COMMENT ON TABLE sales_quote_customer_templates IS 'Customer-scoped reusable quotation layouts; similarity ignores customer content and price';
COMMENT ON TABLE sales_quote_template_versions IS 'Immutable sanitized presentation snapshots, no original customer cells/formulas/links/images';
COMMENT ON TABLE sales_quote_template_evidence IS 'Each intake job confirms one customer template at most once';

SELECT fn_audit_track_table('sales_quote_template_candidates', 'NONE', 'data_change', false);
SELECT fn_audit_track_table('sales_quote_customer_templates', 'NONE', 'data_change', false);
SELECT fn_audit_track_table('sales_quote_template_versions', 'NONE', 'data_change', false);
SELECT fn_audit_track_table('sales_quote_template_evidence', 'NONE', 'data_change', false);
DO $reset_policy$
DECLARE definition text; anchor text := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition) - length(replace(definition, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'V745 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition, anchor, anchor
        || E',\n            (''sales_quote_template_candidates'', ''CLEAR''),'
        || E'\n            (''sales_quote_template_evidence'', ''CLEAR''),'
        || E'\n            (''sales_quote_customer_templates'', ''PRESERVE''),'
        || E'\n            (''sales_quote_template_versions'', ''PRESERVE'')');
END;
$reset_policy$;

INSERT INTO permissions (code,name,module,category,sort_order,action_type,description,grant_policy,high_risk)
VALUES ('sales_quote:export','导出销售报价单','销售管理','销售报价单',208,'EXPORT',
        '下载有权查看的销售报价，可选择客户已学习的一个或多个模板；另需销售订单价格查看权限',
        ARRAY['NORMAL']::text[],false)
ON CONFLICT (code) DO NOTHING;
INSERT INTO permission_surface_permissions(surface_id,permission_id)
SELECT s.id,p.id FROM permission_surfaces s CROSS JOIN permissions p
WHERE s.surface_key = 'sales.quote' AND p.code = 'sales_quote:export'
ON CONFLICT DO NOTHING;
INSERT INTO department_permissions(department_id,permission_id)
SELECT DISTINCT held.department_id,p.id FROM department_permissions held
JOIN permissions source ON source.id = held.permission_id AND source.code = 'sales_quote:view'
CROSS JOIN permissions p WHERE p.code = 'sales_quote:export'
ON CONFLICT DO NOTHING;
