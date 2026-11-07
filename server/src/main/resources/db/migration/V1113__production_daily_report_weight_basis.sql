-- Preserve the input method, goods-master basis and explicit quantity rounding on new report lines.
-- Existing weight and quantity facts keep their original meaning and storage precision.
ALTER TABLE production_daily_report_items
    ADD COLUMN weight_entry_mode text,
    ADD COLUMN unit_weight_kg numeric,
    ADD COLUMN weight_quantity_scale integer,
    ADD COLUMN weight_quantity_rounding text,
    ADD CONSTRAINT production_daily_report_weight_basis_chk CHECK (
        CASE WHEN weight_entry_mode IS NULL THEN
            unit_weight_kg IS NULL AND weight_quantity_scale IS NULL AND weight_quantity_rounding IS NULL
        ELSE unit_weight_kg IS NOT NULL AND unit_weight_kg > 0 AND fn_financial_amount_is_exact(unit_weight_kg)
            AND CASE weight_entry_mode
                WHEN 'QUANTITY' THEN (weight IS NULL OR weight >= 0 AND fn_financial_amount_is_exact(weight))
                    AND weight_quantity_scale IS NULL AND weight_quantity_rounding IS NULL
                WHEN 'WEIGHT' THEN weight IS NOT NULL AND weight >= 0 AND fn_financial_amount_is_exact(weight) AND (
                    (weight_quantity_scale IS NULL AND weight_quantity_rounding IS NULL)
                    OR (weight_quantity_scale IS NOT NULL AND weight_quantity_scale BETWEEN 0 AND 4
                        AND weight_quantity_rounding IS NOT NULL AND weight_quantity_rounding IN ('HALF_UP', 'DOWN')))
                ELSE FALSE
            END
        END
    ) NOT VALID;

ALTER TABLE production_daily_report_items VALIDATE CONSTRAINT production_daily_report_weight_basis_chk;

COMMENT ON COLUMN production_daily_report_items.unit_weight_kg IS
    'Goods master kg per base unit at reporting. Nullable on historical lines or when no basis is configured.';
COMMENT ON COLUMN production_daily_report_items.weight IS
    'Actual recorded mass in kilograms for this output slice. Quantity-mode reference mass is not recorded as measured.';
