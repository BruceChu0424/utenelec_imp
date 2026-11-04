-- Reviewed template-only inputs. They never rewrite inventory, income, COGS or payroll facts.
CREATE TABLE finance_sales_cost_inputs (
    period char(7) NOT NULL CHECK(period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
    client_id uuid NOT NULL REFERENCES clients(id),
    channel text CHECK(channel IN('OEM','FOREIGN','DOMESTIC')),
    tax_rate numeric CHECK(tax_rate IN(0,0.10)),
    freight_local numeric CHECK(fn_financial_amount_is_exact(freight_local)),
    exchange_rate numeric CHECK(exchange_rate>0 AND fn_financial_amount_is_exact(exchange_rate)),
    confirmed boolean NOT NULL DEFAULT false,
    source_reference text CHECK(source_reference IS NULL OR length(source_reference)<=1000),
    client_name_snapshot text, seller_name_snapshot text, region_snapshot text, director_snapshot text,
    row_version bigint NOT NULL DEFAULT 0, updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid NOT NULL REFERENCES users(id), PRIMARY KEY(period,client_id)
);
CREATE TABLE finance_plastic_template_inputs (
    period_line_id uuid PRIMARY KEY REFERENCES workshop_material_period_lines(id),
    source_close_id uuid NOT NULL REFERENCES workshop_material_period_closes(id),
    source_unit_id uuid REFERENCES units(id),
    weight_kg_per_unit numeric CHECK(weight_kg_per_unit>0 AND weight_kg_per_unit=trunc(weight_kg_per_unit,10) AND weight_kg_per_unit<1e14),
    material_name text CHECK(material_name IS NULL OR length(material_name)<=240),
    template_row integer CHECK(template_row BETWEEN 1 AND 2000),
    reject_return_qty numeric(18,4) NOT NULL CHECK(reject_return_qty>=0),
    reject_issue_qty numeric(18,4) NOT NULL CHECK(reject_issue_qty>=0),
    reason text CHECK(reason IS NULL OR length(reason)<=2000), confirmed boolean NOT NULL DEFAULT false,
    source_reference text CHECK(source_reference IS NULL OR length(source_reference)<=1000),
    row_version bigint NOT NULL DEFAULT 0, updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid NOT NULL REFERENCES users(id)
);
CREATE TABLE finance_material_order_references (
    requisition_id uuid PRIMARY KEY REFERENCES workshop_material_requisitions(id),
    order_no text NOT NULL CHECK(length(btrim(order_no)) BETWEEN 1 AND 200),
    source_reference text NOT NULL CHECK(length(btrim(source_reference)) BETWEEN 1 AND 1000),
    confirmed boolean NOT NULL DEFAULT false, row_version bigint NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid NOT NULL REFERENCES users(id)
);
CREATE TABLE finance_cost_input_operations (
    request_id uuid PRIMARY KEY, actor_id uuid NOT NULL REFERENCES users(id),
    kind text NOT NULL CHECK(kind IN('SALES','PLASTIC','ORDER','COPPER')),
    fingerprint text NOT NULL CHECK(fingerprint ~ '^[0-9a-f]{64}$'), result jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE finance_copper_template_inputs (
    source_line_id uuid PRIMARY KEY REFERENCES subcontract_receipt_items(id),
    supplier_id uuid NOT NULL REFERENCES suppliers(id),goods_id uuid NOT NULL REFERENCES goods(id),
    section_key text NOT NULL CHECK(section_key IN('PICKLING_INSERT','COPPER_PICKLING')),
    source_reference text NOT NULL CHECK(length(btrim(source_reference)) BETWEEN 1 AND 1000),
    confirmed boolean NOT NULL DEFAULT false,row_version bigint NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now(),updated_by uuid NOT NULL REFERENCES users(id)
);
CREATE TRIGGER trg_audit_finance_copper_template_inputs AFTER INSERT OR UPDATE OR DELETE ON finance_copper_template_inputs
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE finance_copper_template_inputs ENABLE ALWAYS TRIGGER trg_audit_finance_copper_template_inputs;
CREATE TABLE finance_template_sources (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),actor_id uuid NOT NULL REFERENCES users(id),
    template_key text NOT NULL,period char(7) NOT NULL CHECK(fn_finance_period_is_valid(period::text)),
    source_name text NOT NULL CHECK(length(source_name)<=500),sha256 text NOT NULL CHECK(sha256 ~ '^[0-9a-f]{64}$'),
    storage_provider text NOT NULL,storage_key text NOT NULL,storage_version text,storage_size bigint NOT NULL CHECK(storage_size>0),
    preview jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(actor_id,template_key,period,sha256)
);
CREATE TRIGGER trg_audit_finance_sales_cost_inputs AFTER INSERT OR UPDATE OR DELETE ON finance_sales_cost_inputs
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_plastic_template_inputs AFTER INSERT OR UPDATE OR DELETE ON finance_plastic_template_inputs
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
CREATE TRIGGER trg_audit_finance_material_order_references AFTER INSERT OR UPDATE OR DELETE ON finance_material_order_references
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
ALTER TABLE finance_sales_cost_inputs ENABLE ALWAYS TRIGGER trg_audit_finance_sales_cost_inputs;
ALTER TABLE finance_plastic_template_inputs ENABLE ALWAYS TRIGGER trg_audit_finance_plastic_template_inputs;
ALTER TABLE finance_material_order_references ENABLE ALWAYS TRIGGER trg_audit_finance_material_order_references;
SELECT fn_audit_track_table('finance_sales_cost_inputs','FULL','data_change',false,NULL,true,NULL);
SELECT fn_audit_track_table('finance_plastic_template_inputs','FULL','data_change',false,NULL,true,NULL);
SELECT fn_audit_track_table('finance_material_order_references','FULL','data_change',false,NULL,true,NULL);
SELECT fn_audit_track_table('finance_copper_template_inputs','FULL','data_change',false,NULL,true,NULL);
SELECT fn_audit_track_table('finance_template_sources','FULL','data_change',false,NULL,true,NULL);
CREATE TRIGGER trg_finance_template_source_immutable BEFORE UPDATE OR DELETE ON finance_template_sources
    FOR EACH ROW EXECUTE FUNCTION fn_reject_update_or_delete();
DO $$ DECLARE definition text; BEGIN
    SELECT pg_get_viewdef('v_private_document_storage_references'::regclass,true) INTO definition;
    definition:=regexp_replace(definition,';[[:space:]]*$','');
    EXECUTE 'CREATE OR REPLACE VIEW v_private_document_storage_references AS '||definition||
        ' UNION SELECT storage_provider,storage_key,storage_version FROM finance_template_sources';
END $$;
