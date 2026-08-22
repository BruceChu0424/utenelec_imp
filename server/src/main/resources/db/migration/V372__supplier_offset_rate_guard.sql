-- V372: until dedicated FX posting exists, an offset must use the same frozen
-- recognition rate on both open items. Persist both snapshots for audit.

ALTER TABLE supplier_open_item_offsets
    ADD COLUMN source_rate NUMERIC(18,6),
    ADD COLUMN target_rate NUMERIC(18,6);

UPDATE supplier_open_item_offsets allocation
SET source_rate=source.exchange_rate,
    target_rate=target.exchange_rate
FROM ar_ap_ledger source,ar_ap_ledger target
WHERE source.id=allocation.source_ledger_id
  AND target.id=allocation.target_ledger_id;

ALTER TABLE supplier_open_item_offsets
    ALTER COLUMN source_rate SET NOT NULL,
    ALTER COLUMN target_rate SET NOT NULL,
    ADD CONSTRAINT supplier_open_item_offsets_rate_positive_chk CHECK(
        source_rate>0 AND target_rate>0),
    ADD CONSTRAINT supplier_open_item_offsets_same_rate_chk CHECK(
        source_rate=target_rate);
