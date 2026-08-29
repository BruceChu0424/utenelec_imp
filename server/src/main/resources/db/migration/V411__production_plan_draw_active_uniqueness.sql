-- A physical DRAW document must have one active production-plan identity.
-- Existing duplicates are ambiguous business facts and are never guessed or
-- silently deleted during migration.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM plan_draw_links
        WHERE is_deleted = FALSE
        GROUP BY plan_id, draw_id
        HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION
            'V411 blocked: duplicate active plan/draw link pairs require reconciliation';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM plan_draw_links
        WHERE is_deleted = FALSE
        GROUP BY draw_id
        HAVING COUNT(DISTINCT plan_id) > 1
    ) THEN
        RAISE EXCEPTION
            'V411 blocked: one active DRAW is linked to multiple production plans';
    END IF;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_pdl_active_plan_draw
    ON plan_draw_links(plan_id, draw_id)
    WHERE is_deleted = FALSE;

CREATE UNIQUE INDEX IF NOT EXISTS uq_pdl_active_draw
    ON plan_draw_links(draw_id)
    WHERE is_deleted = FALSE;

COMMENT ON INDEX uq_pdl_active_plan_draw IS
    'Prevents duplicate active plan-to-DRAW relationship rows.';
COMMENT ON INDEX uq_pdl_active_draw IS
    'A physical DRAW document has exactly one active production-plan owner.';
