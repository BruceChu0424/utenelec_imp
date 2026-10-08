WITH input AS MATERIALIZED (SELECT * FROM %s), changed AS MATERIALIZED (
    SELECT material.id FROM production_material_analysis_materials material
    JOIN input ON input.material_id=material.id
    WHERE material.analysis_id=:analysisId AND material.active AND (
        material.confirmed_route IS DISTINCT FROM input.route
        OR material.source_suggestion IS DISTINCT FROM input.suggestion
        OR material.route_reason IS DISTINCT FROM input.reason
        OR material.route_confirmed_by IS NULL OR material.route_confirmed_at IS NULL)
    ORDER BY input._position FOR UPDATE OF material
)
UPDATE production_material_analysis_materials material
SET confirmed_route = input.route, source_suggestion = input.suggestion,
    route_reason = input.reason, route_confirmed_by = :actorId,
    route_confirmed_at = now(), updated_at = now(), updated_by = :actorId
FROM input JOIN changed ON changed.id=input.material_id
WHERE material.id=input.material_id AND material.analysis_id=:analysisId AND material.active
