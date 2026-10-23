-- V903 resolves outstanding retired materials after a usable recipe is written.
-- Resolve once per statement, not once per inserted/updated edge. A bulk import
-- otherwise repeats the same retirement lookup for every row of its final graph.
-- Component status fences, retirement/cost/version/audit functions stay intact.

CREATE INDEX idx_goods_bom_retirement_pending
    ON goods_bom_items(goods_id)
    WHERE is_deleted AND retirement_reason='COMPONENT_DISABLED'
      AND retirement_resolved_at IS NULL;

DROP TRIGGER trg_resolve_disabled_bom_retirements ON goods_bom_items;

CREATE OR REPLACE FUNCTION fn_resolve_disabled_bom_after_write() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE parents UUID[];
BEGIN
    SELECT array_agg(DISTINCT written.goods_id ORDER BY written.goods_id) INTO parents
    FROM written_bom_retirement_rows written
    WHERE NOT written.is_deleted AND written.hard_gate
      AND written.control_stage IN('START','ASSEMBLY','FINISH');
    -- The resolver only updates deleted rows. Their nested UPDATE transition
    -- table has no usable live edge, so it cannot recursively call the resolver.
    -- Empty statements and historical-only edits also do no retirement work.
    IF parents IS NOT NULL THEN
        PERFORM fn_resolve_disabled_bom_retirements(parents);
    END IF;
    RETURN NULL;
END $$;

-- PostgreSQL requires distinct triggers when transition tables and multiple
-- events are involved; UPDATE OF column lists cannot use transition tables.
CREATE TRIGGER trg_resolve_disabled_bom_retirements_ins AFTER INSERT ON goods_bom_items
    REFERENCING NEW TABLE AS written_bom_retirement_rows
    FOR EACH STATEMENT EXECUTE FUNCTION fn_resolve_disabled_bom_after_write();
CREATE TRIGGER trg_resolve_disabled_bom_retirements_upd AFTER UPDATE ON goods_bom_items
    REFERENCING NEW TABLE AS written_bom_retirement_rows
    FOR EACH STATEMENT EXECUTE FUNCTION fn_resolve_disabled_bom_after_write();
