-- The setting is consumed by the root-owned local updater scheduler.
-- No OSS request or operating-system command runs inside the application.
-- Preserve a previously configured value if this seed already exists.
INSERT INTO system_settings (key, value)
VALUES ('updater_check_interval_days', '7')
ON CONFLICT (key) DO NOTHING;
