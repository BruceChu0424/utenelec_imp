-- A proposal may omit its reason. Supplied reasons still use the existing
-- trimmed 2–500 character check, and returning a proposal still requires one.
ALTER TABLE production_overproduction_rate_requests
    ALTER COLUMN reason DROP NOT NULL;
