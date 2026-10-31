-- Voucher references participate in financial reverse lookups and FK checks.
-- V974 is already applied: add the missing leading indexes without changing
-- historical migration bytes, source uniqueness or any financial facts.
CREATE INDEX idx_fixed_assets_recognition_voucher
    ON fixed_assets (recognition_voucher_id);
CREATE INDEX idx_deferred_expenses_recognition_voucher
    ON deferred_expenses (recognition_voucher_id);
CREATE INDEX idx_asset_recognition_reversal_original_voucher
    ON finance_asset_recognition_reversals (original_voucher_id);
CREATE INDEX idx_asset_recognition_reversal_reversal_voucher
    ON finance_asset_recognition_reversals (reversal_voucher_id);
