-- V161: production material accounting is an immutable, append-only ledger.
--
-- Corrections are represented by new ISSUE_REVERSE / GOOD_RETURN_REVERSE
-- stock postings or by a new REVERSE settlement event and posting.  Updating
-- or deleting an accepted fact would break idempotency, auditability and the
-- material-clearance equation.

CREATE OR REPLACE FUNCTION fn_reject_production_material_ledger_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION USING
        ERRCODE = '55000',
        MESSAGE = format(
            '%s is an append-only production material ledger; %s is forbidden',
            TG_TABLE_NAME,
            TG_OP
        ),
        DETAIL = 'Accepted production material events and postings are immutable.',
        HINT = 'Append the matching reversal event and posting instead.',
        CONSTRAINT = TG_TABLE_NAME || '_append_only_guard';
    RETURN NULL;
END;
$$;

-- Remove the inherited cascade path as defense in depth.  The event-row guard
-- below is authoritative and gives callers a domain-specific error; RESTRICT
-- also prevents child facts from disappearing if a trigger is ever disabled
-- during controlled maintenance.
ALTER TABLE production_material_stock_postings
    DROP CONSTRAINT production_material_stock_postings_event_id_fkey,
    ADD CONSTRAINT production_material_stock_postings_event_id_fkey
        FOREIGN KEY (event_id)
        REFERENCES production_material_stock_events(id)
        ON DELETE RESTRICT;

ALTER TABLE production_material_settlement_postings
    DROP CONSTRAINT production_material_settlement_postings_event_id_fkey,
    ADD CONSTRAINT production_material_settlement_postings_event_id_fkey
        FOREIGN KEY (event_id)
        REFERENCES production_material_settlement_events(id)
        ON DELETE RESTRICT;

CREATE TRIGGER trg_00_reject_production_material_stock_event_mutation
    BEFORE UPDATE OR DELETE ON production_material_stock_events
    FOR EACH ROW
    EXECUTE FUNCTION fn_reject_production_material_ledger_mutation();

CREATE TRIGGER trg_00_reject_production_material_stock_posting_mutation
    BEFORE UPDATE OR DELETE ON production_material_stock_postings
    FOR EACH ROW
    EXECUTE FUNCTION fn_reject_production_material_ledger_mutation();

CREATE TRIGGER trg_00_reject_production_material_settlement_event_mutation
    BEFORE UPDATE OR DELETE ON production_material_settlement_events
    FOR EACH ROW
    EXECUTE FUNCTION fn_reject_production_material_ledger_mutation();

CREATE TRIGGER trg_00_reject_production_material_settlement_posting_mutation
    BEFORE UPDATE OR DELETE ON production_material_settlement_postings
    FOR EACH ROW
    EXECUTE FUNCTION fn_reject_production_material_ledger_mutation();

-- Replication-role sessions must not silently turn accounting facts mutable.
ALTER TABLE production_material_stock_events
    ENABLE ALWAYS TRIGGER
        trg_00_reject_production_material_stock_event_mutation;
ALTER TABLE production_material_stock_postings
    ENABLE ALWAYS TRIGGER
        trg_00_reject_production_material_stock_posting_mutation;
ALTER TABLE production_material_settlement_events
    ENABLE ALWAYS TRIGGER
        trg_00_reject_production_material_settlement_event_mutation;
ALTER TABLE production_material_settlement_postings
    ENABLE ALWAYS TRIGGER
        trg_00_reject_production_material_settlement_posting_mutation;

COMMENT ON FUNCTION fn_reject_production_material_ledger_mutation() IS
    'Reject UPDATE/DELETE on production material ledgers; corrections append reversal facts.';
COMMENT ON TABLE production_material_stock_events IS
    'Append-only stock movement event ledger. Never UPDATE or DELETE.';
COMMENT ON TABLE production_material_stock_postings IS
    'Append-only stock allocation posting ledger. Reverse with a new posting.';
COMMENT ON TABLE production_material_settlement_events IS
    'Append-only production material settlement event ledger.';
COMMENT ON TABLE production_material_settlement_postings IS
    'Append-only consumption/loss/WIP posting ledger. Reverse with a new event and posting.';
