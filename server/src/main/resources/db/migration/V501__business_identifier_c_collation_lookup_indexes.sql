-- Trigger arguments such as TG_TABLE_NAME have C collation. PostgreSQL carries
-- that collation into text parameters of the identifier/prefix claim functions.
-- Their exact lookups cannot use the default-collation primary-key indexes on
-- a database whose default locale differs from C, so every new document scans
-- its ever-growing identifier history. Keep all existing uniqueness/ownership
-- rules and data bytes; add matching lookup indexes for this legitimate path.
CREATE INDEX idx_business_identifier_reserved_c_lookup
    ON business_identifier_reservations (normalized_identifier COLLATE "C");

CREATE INDEX idx_business_identifier_members_c_lookup
    ON business_identifier_reservation_members
        (normalized_identifier COLLATE "C", owner_domain COLLATE "C", entity_id);

CREATE INDEX idx_business_prefix_reserved_c_lookup
    ON business_prefix_reservations (normalized_prefix COLLATE "C");

CREATE INDEX idx_business_prefix_members_c_lookup
    ON business_prefix_reservation_members
        (normalized_prefix COLLATE "C", owner_kind COLLATE "C", owner_key COLLATE "C");
