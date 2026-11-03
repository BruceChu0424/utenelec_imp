-- Keep the previously committed V993 source bytes unchanged, including on development
-- databases that already installed the original FULL registration.
-- Storage events are the append-only physical-location journal. Source stock
-- documents/reservations retain their FULL audit; immutable document and
-- transaction lineage retain each event's business owner. Positions are the
-- replayable remaining-quantity projection, not a manually maintained master.
-- Only the generic row-audit policy changes; business immutability/provenance
-- triggers, event rows, quantities and reservation ownership remain intact.
SELECT public.fn_audit_track_table(
    'stock_reservation_storage_events', 'NONE', 'data_change', false);
SELECT public.fn_audit_track_table(
    'stock_reservation_storage_positions', 'NONE', 'data_change', false);
