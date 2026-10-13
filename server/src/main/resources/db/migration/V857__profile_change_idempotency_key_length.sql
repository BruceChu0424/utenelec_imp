-- SubmitRequest permits a 128-character command key and a 64-character field
-- code. Preserve the full key:fieldCode identity, including existing receipts.
ALTER TABLE profile_change_requests
    ALTER COLUMN idem_key TYPE VARCHAR(193);
