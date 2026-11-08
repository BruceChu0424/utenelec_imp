-- Preserve a report-local unit weight without changing the goods master or legacy basis.
ALTER TABLE production_daily_report_items
    ADD COLUMN unit_weight_source text,
    ADD COLUMN weight_unit_scale integer,
    ADD COLUMN weight_unit_rounding text,
    DROP CONSTRAINT production_daily_report_weight_basis_chk,
    ADD CONSTRAINT production_daily_report_weight_basis_chk CHECK (
        CASE WHEN weight_entry_mode IS NULL THEN
            unit_weight_kg IS NULL AND unit_weight_source IS NULL
            AND weight_quantity_scale IS NULL AND weight_quantity_rounding IS NULL
            AND weight_unit_scale IS NULL AND weight_unit_rounding IS NULL
        ELSE unit_weight_kg IS NOT NULL AND unit_weight_kg > 0 AND fn_financial_amount_is_exact(unit_weight_kg)
            AND CASE weight_entry_mode
                WHEN 'QUANTITY' THEN COALESCE(unit_weight_source, 'MASTER') IN ('MASTER', 'MANUAL')
                    AND (weight IS NULL OR (unit_weight_source IS DISTINCT FROM 'MANUAL'
                        AND weight >= 0 AND fn_financial_amount_is_exact(weight)))
                    AND weight_quantity_scale IS NULL AND weight_quantity_rounding IS NULL
                    AND weight_unit_scale IS NULL AND weight_unit_rounding IS NULL
                WHEN 'WEIGHT' THEN COALESCE(unit_weight_source, 'MASTER') IN ('MASTER', 'MANUAL')
                    AND weight IS NOT NULL AND weight >= 0 AND fn_financial_amount_is_exact(weight)
                    AND weight_unit_scale IS NULL AND weight_unit_rounding IS NULL
                    AND ((weight_quantity_scale IS NULL AND weight_quantity_rounding IS NULL)
                        OR (weight_quantity_scale IS NOT NULL AND weight_quantity_scale BETWEEN 0 AND 4
                            AND weight_quantity_rounding IS NOT NULL AND weight_quantity_rounding IN ('HALF_UP', 'DOWN')))
                WHEN 'UNIT' THEN unit_weight_source IS NOT DISTINCT FROM 'DERIVED'
                    AND weight IS NOT NULL AND weight >= 0 AND fn_financial_amount_is_exact(weight)
                    AND weight_quantity_scale IS NULL AND weight_quantity_rounding IS NULL
                    AND ((weight_unit_scale IS NULL AND weight_unit_rounding IS NULL)
                        OR (weight_unit_scale IS NOT NULL AND weight_unit_scale BETWEEN 0 AND 24
                            AND weight_unit_rounding IS NOT NULL AND weight_unit_rounding IN ('HALF_UP', 'DOWN')))
                ELSE FALSE
            END
        END
    ) NOT VALID;

ALTER TABLE production_daily_report_items VALIDATE CONSTRAINT production_daily_report_weight_basis_chk;

COMMENT ON COLUMN production_daily_report_items.unit_weight_kg IS
    'Frozen kg per base unit used for this output batch. May be goods master, report-local manual input, or derived.';
COMMENT ON COLUMN production_daily_report_items.unit_weight_source IS
    'Null or MASTER uses goods master. MANUAL and DERIVED apply only to this report batch.';
