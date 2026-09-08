-- V477: route reasons are optional for every manually confirmed supply route.
-- Existing confirmation identity/time and legal-route guards remain mandatory.
-- This is a forward relaxation: do not rewrite historical reasons or V234.

ALTER TABLE production_material_analysis_materials
    DROP CONSTRAINT production_material_analysis_material_route_reason_chk;

ALTER TABLE production_material_analysis_materials
    ADD CONSTRAINT production_material_analysis_material_route_reason_chk CHECK (
        (confirmed_route IS NULL
            AND route_reason IS NULL
            AND route_confirmed_by IS NULL
            AND route_confirmed_at IS NULL)
        OR
        (confirmed_route IS NOT NULL
            AND confirmed_route IN ('BUY', 'MAKE', 'SUBCONTRACT')
            AND route_confirmed_by IS NOT NULL
            AND route_confirmed_at IS NOT NULL
            AND (route_reason IS NULL
                OR length(btrim(route_reason)) BETWEEN 1 AND 1000))
    ) NOT VALID;

ALTER TABLE production_material_analysis_materials
    VALIDATE CONSTRAINT production_material_analysis_material_route_reason_chk;

COMMENT ON COLUMN production_material_analysis_materials.route_reason IS
    'Optional reason for manual route confirmation; blank input is normalized to NULL by the application. Confirming user and time remain mandatory.';
