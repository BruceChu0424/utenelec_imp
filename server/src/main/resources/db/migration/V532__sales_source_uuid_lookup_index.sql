-- Order attribution starts from the immutable source UUID, then follows ledger_id.
-- Existing indexes start from ledger_id or source_no and cannot bound this lookup.
-- Keep business data and uniqueness rules unchanged; an unexpected name collision fails.
CREATE INDEX idx_ar_ap_source_refs_source_uuid
    ON ar_ap_source_refs (source_type, source_id, ledger_id);
