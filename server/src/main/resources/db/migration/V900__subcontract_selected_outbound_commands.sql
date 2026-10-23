-- A warehouse selection is an immutable execution slice of the original draw.
-- Unselected draw rows and their stock reservations remain on the source draft.
CREATE TABLE subcontract_selected_outbound_commands (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id UUID NOT NULL REFERENCES users(id),
    idempotency_key VARCHAR(128) NOT NULL CHECK(idempotency_key ~ '^[A-Za-z0-9._:-]{8,128}$'),
    request_hash CHAR(64) NOT NULL CHECK(request_hash ~ '^[0-9a-f]{64}$'),
    request_json JSONB NOT NULL CHECK(jsonb_typeof(request_json)='object'),
    source_issue_id UUID NOT NULL REFERENCES subcontract_material_issues(id),
    execution_issue_id UUID NOT NULL UNIQUE REFERENCES subcontract_material_issues(id),
    execution_bill_no TEXT NOT NULL,
    selected_item_ids UUID[] NOT NULL CHECK (cardinality(selected_item_ids) BETWEEN 1 AND 500),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(actor_id, idempotency_key)
);

CREATE TABLE subcontract_selected_outbound_items (
    command_id UUID NOT NULL REFERENCES subcontract_selected_outbound_commands(id),
    source_item_id UUID PRIMARY KEY REFERENCES subcontract_material_issue_items(id),
    execution_item_id UUID NOT NULL UNIQUE REFERENCES subcontract_material_issue_items(id)
);
ALTER TABLE subcontract_material_issue_items
    ADD COLUMN warehouse_split_at TIMESTAMPTZ,
    ADD COLUMN warehouse_split_command_id UUID REFERENCES subcontract_selected_outbound_commands(id),
    ADD CONSTRAINT subcontract_outbound_split_retirement_shape CHECK (
        (warehouse_split_at IS NULL)=(warehouse_split_command_id IS NULL)
        AND (warehouse_split_at IS NULL OR (is_deleted AND warehouse_dropped_at IS NULL)));

CREATE FUNCTION fn_guard_subcontract_selected_outbound_command() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'selected outbound command receipts are immutable' USING ERRCODE='23514';
END;
$$;
CREATE TRIGGER trg_guard_subcontract_selected_outbound_command
    BEFORE UPDATE OR DELETE ON subcontract_selected_outbound_commands
    FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_selected_outbound_command();
ALTER TABLE subcontract_selected_outbound_commands ENABLE ALWAYS TRIGGER trg_guard_subcontract_selected_outbound_command;
CREATE TRIGGER trg_guard_subcontract_selected_outbound_items
    BEFORE UPDATE OR DELETE ON subcontract_selected_outbound_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_selected_outbound_command();
ALTER TABLE subcontract_selected_outbound_items ENABLE ALWAYS TRIGGER trg_guard_subcontract_selected_outbound_items;

CREATE FUNCTION fn_guard_subcontract_selected_outbound_lineage() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM subcontract_selected_outbound_commands command
        JOIN subcontract_material_issues source ON source.id=command.source_issue_id
        JOIN subcontract_material_issues execution ON execution.id=command.execution_issue_id
        JOIN subcontract_material_issue_items original ON original.id=NEW.source_item_id AND original.issue_id=source.id
        JOIN subcontract_material_issue_items target ON target.id=NEW.execution_item_id AND target.issue_id=execution.id
        WHERE command.id=NEW.command_id AND NEW.source_item_id=ANY(command.selected_item_ids)
          AND source.status=0 AND execution.status=0 AND NOT source.is_deleted AND NOT execution.is_deleted
          AND source.supplier_id IS NOT DISTINCT FROM execution.supplier_id
          AND source.maker_id IS NOT DISTINCT FROM execution.maker_id
          AND source.owner_pool IS NOT DISTINCT FROM execution.owner_pool
          AND NOT original.is_deleted AND NOT target.is_deleted AND original.plan_item_id IS NOT NULL
          AND original.plan_item_id=target.plan_item_id AND original.requested_qty=target.requested_qty
          AND original.order_item_id IS NOT DISTINCT FROM target.order_item_id
          AND original.goods_id=target.goods_id AND original.color_id IS NOT DISTINCT FROM target.color_id
          AND original.unit_id IS NOT DISTINCT FROM target.unit_id AND original.unit_rate IS NOT DISTINCT FROM target.unit_rate
          AND ((source.id=execution.id AND original.id=target.id) OR (source.id<>execution.id AND original.id<>target.id))
    ) THEN
        RAISE EXCEPTION 'selected outbound lineage must preserve the original frozen material and parent identity' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_subcontract_selected_outbound_lineage BEFORE INSERT ON subcontract_selected_outbound_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_selected_outbound_lineage();
ALTER TABLE subcontract_selected_outbound_items ENABLE ALWAYS TRIGGER trg_guard_subcontract_selected_outbound_lineage;

CREATE FUNCTION fn_guard_subcontract_selected_outbound_retirement() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP='INSERT' THEN
        IF NEW.warehouse_split_command_id IS NOT NULL THEN
            RAISE EXCEPTION 'a source draw row must exist before selected execution retires it' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
    END IF;
    IF OLD.warehouse_split_command_id IS NOT NULL THEN
        IF NEW.warehouse_split_command_id IS DISTINCT FROM OLD.warehouse_split_command_id
           OR NEW.warehouse_split_at IS DISTINCT FROM OLD.warehouse_split_at
           OR NOT NEW.is_deleted OR NEW.warehouse_dropped_at IS DISTINCT FROM OLD.warehouse_dropped_at THEN
            RAISE EXCEPTION 'selected outbound source retirement is immutable' USING ERRCODE='23514';
        END IF;
    ELSIF NEW.warehouse_split_command_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM subcontract_selected_outbound_items lineage
        JOIN subcontract_selected_outbound_commands command ON command.id=lineage.command_id
        WHERE lineage.source_item_id=NEW.id AND lineage.execution_item_id<>NEW.id
          AND command.id=NEW.warehouse_split_command_id AND command.source_issue_id=NEW.issue_id
          AND NEW.is_deleted AND NEW.warehouse_dropped_at IS NULL AND NEW.warehouse_split_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'source draw retirement requires its immutable execution lineage' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_guard_subcontract_selected_outbound_retirement BEFORE INSERT OR UPDATE OF
    is_deleted,warehouse_dropped_at,warehouse_split_at,warehouse_split_command_id ON subcontract_material_issue_items
    FOR EACH ROW EXECUTE FUNCTION fn_guard_subcontract_selected_outbound_retirement();
ALTER TABLE subcontract_material_issue_items ENABLE ALWAYS TRIGGER trg_guard_subcontract_selected_outbound_retirement;

CREATE FUNCTION fn_assert_subcontract_selected_outbound_complete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF cardinality(NEW.selected_item_ids)<>(SELECT count(DISTINCT item) FROM unnest(NEW.selected_item_ids) item)
       OR NOT EXISTS (SELECT 1 FROM subcontract_material_issues WHERE id=NEW.execution_issue_id AND status=1 AND NOT is_deleted)
       OR cardinality(NEW.selected_item_ids)<>(SELECT count(*) FROM subcontract_material_issue_items
                                              WHERE issue_id=NEW.execution_issue_id AND NOT is_deleted)
       OR cardinality(NEW.selected_item_ids)<>(SELECT count(*) FROM subcontract_selected_outbound_items WHERE command_id=NEW.id)
       OR EXISTS (SELECT 1 FROM unnest(NEW.selected_item_ids) selected(id)
                  LEFT JOIN subcontract_selected_outbound_items lineage ON lineage.source_item_id=selected.id AND lineage.command_id=NEW.id
                  LEFT JOIN subcontract_material_issue_items original ON original.id=selected.id
                  LEFT JOIN subcontract_material_issue_items target ON target.id=lineage.execution_item_id
                  WHERE original.id IS NULL OR original.issue_id<>NEW.source_issue_id OR target.id IS NULL
                    OR target.is_deleted OR target.issue_id<>NEW.execution_issue_id
                    OR (NEW.source_issue_id<>NEW.execution_issue_id AND (NOT original.is_deleted
                         OR original.warehouse_split_command_id IS DISTINCT FROM NEW.id OR original.warehouse_dropped_at IS NOT NULL))) THEN
        RAISE EXCEPTION 'selected outbound must commit its exact approved execution slice' USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER trg_assert_subcontract_selected_outbound_complete
    AFTER INSERT ON subcontract_selected_outbound_commands DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_assert_subcontract_selected_outbound_complete();

SELECT fn_audit_track_table('subcontract_selected_outbound_commands', 'FULL', 'data_change', false);
SELECT fn_audit_track_table('subcontract_selected_outbound_items', 'FULL', 'data_change', false);
DO $reset_policy$
DECLARE definition TEXT; anchor TEXT := '(''stock_movements'', ''CLEAR'')';
BEGIN
    SELECT pg_get_functiondef('business_data_reset()'::regprocedure) INTO definition;
    IF (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 THEN
        RAISE EXCEPTION 'V900 cannot extend business-data reset policy safely';
    END IF;
    EXECUTE replace(definition,anchor,anchor||E',\n (''subcontract_selected_outbound_commands'', ''CLEAR''),\n (''subcontract_selected_outbound_items'', ''CLEAR'')');
END;
$reset_policy$;
