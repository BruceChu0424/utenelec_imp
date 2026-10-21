-- Portable company policy follows the existing preserved, audited settings registry.
-- Existing choices, especially an explicit false, survive upgrades and restore.
INSERT INTO system_settings(key,value) VALUES
 ('material_forecast.enabled','true'),
 ('material_forecast.interval_minutes','15'),
 ('material_forecast.history_days','1200'),
 ('material_forecast.backfill_budget','30')
ON CONFLICT(key) DO NOTHING;
