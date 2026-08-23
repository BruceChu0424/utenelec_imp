-- V368: transaction timestamps and random UUIDs do not encode insertion order.
-- Persist explicit sequences so multi-line claim/offset reversal is provably LIFO.

ALTER TABLE subcontract_loss_resolutions ADD COLUMN resolution_seq INTEGER;
WITH ranked AS (
    SELECT id,ROW_NUMBER() OVER(PARTITION BY case_id ORDER BY created_at,id)::INTEGER seq
    FROM subcontract_loss_resolutions)
UPDATE subcontract_loss_resolutions row SET resolution_seq=ranked.seq
FROM ranked WHERE ranked.id=row.id;
ALTER TABLE subcontract_loss_resolutions
    ALTER COLUMN resolution_seq SET NOT NULL,
    ADD CONSTRAINT subcontract_loss_resolutions_seq_chk CHECK (resolution_seq>0),
    ADD CONSTRAINT subcontract_loss_resolutions_case_seq_uk UNIQUE(case_id,resolution_seq);

ALTER TABLE supplier_open_item_offsets ADD COLUMN line_sequence INTEGER;
WITH ranked AS (
    SELECT id,ROW_NUMBER() OVER(PARTITION BY offset_batch_id ORDER BY created_at,id)::INTEGER seq
    FROM supplier_open_item_offsets)
UPDATE supplier_open_item_offsets row SET line_sequence=ranked.seq
FROM ranked WHERE ranked.id=row.id;
ALTER TABLE supplier_open_item_offsets
    ALTER COLUMN line_sequence SET NOT NULL,
    ADD CONSTRAINT supplier_open_item_offsets_seq_chk CHECK(line_sequence>0),
    ADD CONSTRAINT supplier_open_item_offsets_batch_seq_uk UNIQUE(offset_batch_id,line_sequence);

CREATE INDEX idx_subcontract_loss_resolutions_reverse
    ON subcontract_loss_resolutions(case_id,resolution_seq DESC);
