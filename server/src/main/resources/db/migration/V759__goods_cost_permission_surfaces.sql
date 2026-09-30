-- V759: V753 cost actions belong to the existing goods detail/cost workspace.
-- Surface mappings expose explicit delegation choices; they do not grant them.
-- V328's goods: prefix rule was a one-time seed, not a runtime expansion rule.
DO $catalog$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM permission_surfaces
        WHERE surface_key = 'basic.goods' AND enabled
    ) THEN
        RAISE EXCEPTION 'V759 requires the enabled basic.goods permission surface';
    END IF;
    IF (SELECT count(*) FROM permissions WHERE code IN (
        'goods:cost:edit', 'goods:cost:confirm',
        'goods:cost:export', 'goods:cost:template'
    )) <> 4 THEN
        RAISE EXCEPTION 'V759 requires the four existing V753 goods cost permissions';
    END IF;
END;
$catalog$;

WITH cost_actions(code) AS (VALUES
    ('goods:cost:edit'),
    ('goods:cost:confirm'),
    ('goods:cost:export'),
    ('goods:cost:template')
)
INSERT INTO permission_surface_permissions(surface_id, permission_id)
SELECT surface.id, permission.id
FROM cost_actions action
JOIN permissions permission ON permission.code = action.code
CROSS JOIN permission_surfaces surface
WHERE surface.surface_key = 'basic.goods' AND surface.enabled
ON CONFLICT (surface_id, permission_id) DO NOTHING;

-- Keep permission identities, BULK_EXCLUDED policy, sensitivity, baseline and
-- all department/user grants unchanged. No retired permission is recreated.
