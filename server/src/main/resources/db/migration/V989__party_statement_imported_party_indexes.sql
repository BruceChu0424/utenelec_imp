-- Imported openings use their proved Shanghai snapshot date, never the old
-- document date. Keep that semantic while avoiding a scan of every native
-- posting just to discover that a party has no imported opening rows.
CREATE INDEX idx_arap_imported_client
    ON ar_ap_ledger(client_id)
    WHERE direction='AR' AND legacy_import_run_id IS NOT NULL;

CREATE INDEX idx_arap_imported_supplier
    ON ar_ap_ledger(supplier_id)
    WHERE direction='AP' AND legacy_import_run_id IS NOT NULL;
