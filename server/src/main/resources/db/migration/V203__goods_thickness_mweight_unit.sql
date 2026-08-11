-- Thickness/单重 currently store a bare number with no unit. Add optional unit
-- references (bridge to units.legacy_id, same pattern as goods.color_legacy_id /
-- goods.unit_legacy_id) so the edit form can pair each number with a unit picker
-- instead of the value being ambiguous (mm vs cm, g vs kg).
ALTER TABLE goods
    ADD COLUMN thickness_unit_legacy_id INTEGER,
    ADD COLUMN m_weight_unit_legacy_id  INTEGER;

COMMENT ON COLUMN goods.thickness_unit_legacy_id IS
    '厚度单位（→ units.legacy_id，同 color/unit_legacy_id 桥接方式；NULL=未指定）';
COMMENT ON COLUMN goods.m_weight_unit_legacy_id IS
    '单重单位（→ units.legacy_id，同 color/unit_legacy_id 桥接方式；NULL=未指定）';
