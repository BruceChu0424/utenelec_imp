-- V289: harden the V288 material-analysis borrow workflow and refresh audit coverage.
--
-- V288 declares each row to be an append-preserved business allocation whose only
-- lifecycle transition is ACTIVE -> REVOKED. Keep the identity and business payload
-- immutable, allow ACTIVE rows to refresh last_effective_qty, forbid physical deletes,
-- make a revoked row fully immutable, and fail closed when a refreshed BOM no longer
-- contains the original active endpoints or changes their immutable material dimension.

CREATE FUNCTION fn_guard_production_material_analysis_borrow_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION USING
            ERRCODE = '55000',
            MESSAGE = 'production material analysis borrows cannot be physically deleted',
            DETAIL = 'Borrow allocation evidence is append-preserved.',
            HINT = 'Use the single ACTIVE to REVOKED transition.',
            CONSTRAINT = 'production_material_analysis_borrow_mutation_guard';
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'ACTIVE'
           OR NEW.revoked_by IS NOT NULL
           OR NEW.revoked_at IS NOT NULL
           OR NEW.revoke_reason IS NOT NULL
           OR NEW.last_effective_qty <> 0 THEN
            RAISE EXCEPTION USING
                ERRCODE = '55000',
                MESSAGE = 'production material analysis borrows must start ACTIVE',
                DETAIL = 'Direct insertion of REVOKED history bypasses the only allowed lifecycle transition.',
                HINT = 'Insert an ACTIVE allocation, then use the controlled ACTIVE to REVOKED transition.',
                CONSTRAINT = 'production_material_analysis_borrow_mutation_guard';
        END IF;
        RETURN NEW;
    END IF;

    IF OLD.status = 'REVOKED' THEN
        RAISE EXCEPTION USING
            ERRCODE = '55000',
            MESSAGE = 'revoked production material analysis borrows are immutable',
            DETAIL = 'A revoked allocation remains historical evidence.',
            CONSTRAINT = 'production_material_analysis_borrow_mutation_guard';
    END IF;

    IF OLD.status <> 'ACTIVE'
       OR NEW.status NOT IN ('ACTIVE', 'REVOKED') THEN
        RAISE EXCEPTION USING
            ERRCODE = '55000',
            MESSAGE = 'invalid production material analysis borrow lifecycle transition',
            DETAIL = format('Only ACTIVE to ACTIVE or ACTIVE to REVOKED is allowed (old=%s, new=%s).',
                            OLD.status, NEW.status),
            CONSTRAINT = 'production_material_analysis_borrow_mutation_guard';
    END IF;

    IF ROW(
        NEW.id,
        NEW.analysis_id,
        NEW.from_material_id,
        NEW.to_material_id,
        NEW.goods_id,
        NEW.color_id,
        NEW.unit_id,
        NEW.qty,
        NEW.reason,
        NEW.idempotency_key,
        NEW.created_by,
        NEW.created_at
    ) IS DISTINCT FROM ROW(
        OLD.id,
        OLD.analysis_id,
        OLD.from_material_id,
        OLD.to_material_id,
        OLD.goods_id,
        OLD.color_id,
        OLD.unit_id,
        OLD.qty,
        OLD.reason,
        OLD.idempotency_key,
        OLD.created_by,
        OLD.created_at
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '55000',
            MESSAGE = 'production material analysis borrow identity and payload are immutable',
            DETAIL = 'Only last_effective_qty or the single ACTIVE to REVOKED transition may change.',
            CONSTRAINT = 'production_material_analysis_borrow_mutation_guard';
    END IF;

    IF NEW.status = 'REVOKED'
       AND NEW.last_effective_qty IS DISTINCT FROM OLD.last_effective_qty THEN
        RAISE EXCEPTION USING
            ERRCODE = '55000',
            MESSAGE = 'revoking a production material analysis borrow cannot change its effective quantity',
            DETAIL = 'The last effective quantity is immutable lifecycle evidence at revocation.',
            CONSTRAINT = 'production_material_analysis_borrow_mutation_guard';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_production_material_analysis_borrow_mutation
    BEFORE INSERT OR UPDATE OR DELETE ON production_material_analysis_borrows
    FOR EACH ROW EXECUTE FUNCTION fn_guard_production_material_analysis_borrow_mutation();

CREATE TRIGGER trg_set_updated_at_production_material_analysis_borrows
    BEFORE UPDATE ON production_material_analysis_borrows
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- Validate the final transaction state, not the temporary state inside refresh. Refresh
-- first marks every material inactive and then reactivates/upserts the current BOM nodes,
-- so an immediate trigger would reject every valid refresh. The deferred constraint
-- triggers below allow that in-transaction rewrite but reject a missing, moved or
-- dimension-drifted endpoint at commit.
CREATE FUNCTION fn_validate_production_material_analysis_borrow_endpoint()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    invalid_borrow_id UUID;
BEGIN
    SELECT borrow.id
    INTO invalid_borrow_id
    FROM production_material_analysis_borrows borrow
    LEFT JOIN production_material_analysis_materials from_material
      ON from_material.id = borrow.from_material_id
    LEFT JOIN production_material_analysis_materials to_material
      ON to_material.id = borrow.to_material_id
    LEFT JOIN production_material_analysis_items from_item
      ON from_item.id = from_material.analysis_item_id
    LEFT JOIN production_material_analysis_items to_item
      ON to_item.id = to_material.analysis_item_id
    WHERE borrow.status = 'ACTIVE'
      AND (
          (TG_TABLE_NAME = 'production_material_analysis_borrows'
              AND borrow.id = NEW.id)
          OR
          (TG_TABLE_NAME = 'production_material_analysis_materials'
              AND (borrow.from_material_id = NEW.id OR borrow.to_material_id = NEW.id))
          OR
          (TG_TABLE_NAME = 'production_material_analysis_items'
              AND (from_material.analysis_item_id = NEW.id
                  OR to_material.analysis_item_id = NEW.id))
      )
      AND (
          from_material.id IS NULL OR to_material.id IS NULL
          OR from_material.analysis_id <> borrow.analysis_id
          OR to_material.analysis_id <> borrow.analysis_id
          OR from_material.active IS DISTINCT FROM TRUE
          OR to_material.active IS DISTINCT FROM TRUE
          OR from_item.id IS NULL OR to_item.id IS NULL
          OR from_item.analysis_id <> borrow.analysis_id
          OR to_item.analysis_id <> borrow.analysis_id
          OR from_item.is_deleted IS DISTINCT FROM FALSE
          OR to_item.is_deleted IS DISTINCT FROM FALSE
          OR from_material.analysis_item_id = to_material.analysis_item_id
          OR from_material.depth <> 1 OR to_material.depth <> 1
          OR from_material.control_stage IN ('SHIP', 'REFERENCE')
          OR to_material.control_stage IN ('SHIP', 'REFERENCE')
          OR from_material.goods_id IS DISTINCT FROM to_material.goods_id
          OR from_material.color_id IS DISTINCT FROM to_material.color_id
          OR from_material.unit_id IS DISTINCT FROM to_material.unit_id
          OR from_material.goods_id IS DISTINCT FROM borrow.goods_id
          OR from_material.color_id IS DISTINCT FROM borrow.color_id
          OR from_material.unit_id IS DISTINCT FROM borrow.unit_id
      )
    ORDER BY borrow.id
    LIMIT 1;

    IF invalid_borrow_id IS NOT NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '55000',
            MESSAGE = 'active production material analysis borrow has invalid endpoints',
            DETAIL = format(
                'Borrow %s endpoints must remain active direct components of different products in the same analysis and immutable material dimension.',
                invalid_borrow_id),
            HINT = 'Revoke the borrow before refreshing or changing either endpoint.',
            CONSTRAINT = 'production_material_analysis_borrow_endpoint_guard';
    END IF;

    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_pma_borrow_endpoint
    AFTER INSERT OR UPDATE ON production_material_analysis_borrows
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_production_material_analysis_borrow_endpoint();

CREATE CONSTRAINT TRIGGER trg_validate_pma_material_borrow_endpoint
    AFTER UPDATE OF analysis_id, analysis_item_id, goods_id, color_id, unit_id,
        depth, control_stage, active
    ON production_material_analysis_materials
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_production_material_analysis_borrow_endpoint();

CREATE CONSTRAINT TRIGGER trg_validate_pma_item_borrow_endpoint
    AFTER UPDATE OF analysis_id, is_deleted ON production_material_analysis_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_validate_production_material_analysis_borrow_endpoint();

COMMENT ON TABLE production_material_analysis_borrows IS
    'Append-preserved material-analysis allocation evidence; active endpoints are transaction-deferred, database-guarded and audited.';

-- V288 creates a business table after the V285 sweep. Refresh and verify full
-- public audit coverage; the borrow business table is not a technical exemption.
DO $$
DECLARE
    table_record RECORD;
    prefixed_trigger_count INTEGER;
    valid_trigger_count INTEGER;
    missing_tables TEXT;
BEGIN
    FOR table_record IN
        SELECT c.oid, c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
          AND c.relname NOT IN (
              'audit_log', 'audit_log_archive', 'flyway_schema_history', 'spatial_ref_sys',
              'authorization_state', 'doc_number_sequences', 'master_code_sequences',
              'category_master_code_sequences', 'business_document_sequences',
              'production_product_no_sequences',
              'report_materialized_view_refresh_state', 'password_history',
              'refresh_tokens', 'visitor_refresh_tokens', 'visitor_sms_codes')
          AND c.relname NOT LIKE 'legacy_migration_%'
        ORDER BY c.relname
    LOOP
        SELECT count(*),
               count(*) FILTER (WHERE
                   audit_trigger.tgenabled IN ('O', 'A')
                   AND (audit_trigger.tgtype::INTEGER & 1) = 1
                   AND (audit_trigger.tgtype::INTEGER & 2) = 0
                   AND (audit_trigger.tgtype::INTEGER & 4) = 4
                   AND (audit_trigger.tgtype::INTEGER & 8) = 8
                   AND (audit_trigger.tgtype::INTEGER & 16) = 16
                   AND function_schema.nspname = 'public'
                   AND audit_function.proname IN ('fn_audit', 'fn_audit_redacted'))
        INTO prefixed_trigger_count, valid_trigger_count
        FROM pg_trigger audit_trigger
        JOIN pg_proc audit_function ON audit_function.oid = audit_trigger.tgfoid
        JOIN pg_namespace function_schema ON function_schema.oid = audit_function.pronamespace
        WHERE audit_trigger.tgrelid = table_record.oid
          AND NOT audit_trigger.tgisinternal
          AND audit_trigger.tgname LIKE 'trg_audit%';

        IF prefixed_trigger_count = 1 AND valid_trigger_count = 1 THEN
            CONTINUE;
        END IF;
        IF prefixed_trigger_count > 0 THEN
            RAISE EXCEPTION
                'public.% has % trg_audit* triggers but exactly one valid enabled AFTER ROW INSERT/UPDATE/DELETE audit trigger is required (valid=%)',
                table_record.relname, prefixed_trigger_count, valid_trigger_count
                USING ERRCODE = '55000';
        END IF;
        EXECUTE format(
            'CREATE TRIGGER trg_audit_%1$I AFTER INSERT OR UPDATE OR DELETE ON %1$I '
            'FOR EACH ROW EXECUTE FUNCTION fn_audit()', table_record.relname);
    END LOOP;

    SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
    INTO missing_tables
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p')
      AND NOT c.relispartition
      AND c.relname NOT IN (
          'audit_log', 'audit_log_archive', 'flyway_schema_history', 'spatial_ref_sys',
          'authorization_state', 'doc_number_sequences', 'master_code_sequences',
          'category_master_code_sequences', 'business_document_sequences',
          'production_product_no_sequences',
          'report_materialized_view_refresh_state', 'password_history',
          'refresh_tokens', 'visitor_refresh_tokens', 'visitor_sms_codes')
      AND c.relname NOT LIKE 'legacy_migration_%'
      AND (
          (SELECT count(*) FROM pg_trigger audit_trigger
           WHERE audit_trigger.tgrelid = c.oid AND NOT audit_trigger.tgisinternal
             AND audit_trigger.tgname LIKE 'trg_audit%') <> 1
          OR
          (SELECT count(*)
           FROM pg_trigger audit_trigger
           JOIN pg_proc audit_function ON audit_function.oid = audit_trigger.tgfoid
           JOIN pg_namespace function_schema ON function_schema.oid = audit_function.pronamespace
           WHERE audit_trigger.tgrelid = c.oid AND NOT audit_trigger.tgisinternal
             AND audit_trigger.tgname LIKE 'trg_audit%'
             AND audit_trigger.tgenabled IN ('O', 'A')
             AND (audit_trigger.tgtype::INTEGER & 1) = 1
             AND (audit_trigger.tgtype::INTEGER & 2) = 0
             AND (audit_trigger.tgtype::INTEGER & 4) = 4
             AND (audit_trigger.tgtype::INTEGER & 8) = 8
             AND (audit_trigger.tgtype::INTEGER & 16) = 16
             AND function_schema.nspname = 'public'
             AND audit_function.proname IN ('fn_audit', 'fn_audit_redacted')) <> 1);

    IF missing_tables IS NOT NULL THEN
        RAISE EXCEPTION 'Audit trigger coverage remains invalid for: %', missing_tables
            USING ERRCODE = '55000';
    END IF;
END $$;
