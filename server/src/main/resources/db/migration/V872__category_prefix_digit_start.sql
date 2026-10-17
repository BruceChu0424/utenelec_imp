-- Category prefixes may start with a digit, including all-numeric prefixes.
-- UUID relationships, lifetime prefix reservations and allocated suffixes retain
-- their existing authority. This widens validation without rewriting any data.
ALTER TABLE material_categories
    DROP CONSTRAINT material_categories_code_prefix_chk,
    ADD CONSTRAINT material_categories_code_prefix_chk
        CHECK (code_prefix IS NULL OR code_prefix ~ '^[A-Z0-9]{1,8}$');
ALTER TABLE mould_categories
    DROP CONSTRAINT mould_categories_code_prefix_chk,
    ADD CONSTRAINT mould_categories_code_prefix_chk
        CHECK (code_prefix IS NULL OR code_prefix ~ '^[A-Z0-9]{1,8}$');
ALTER TABLE client_categories
    DROP CONSTRAINT client_categories_code_prefix_chk,
    ADD CONSTRAINT client_categories_code_prefix_chk
        CHECK (code_prefix IS NULL OR code_prefix ~ '^[A-Z0-9]{1,8}$');
ALTER TABLE supplier_categories
    DROP CONSTRAINT supplier_categories_code_prefix_chk,
    ADD CONSTRAINT supplier_categories_code_prefix_chk
        CHECK (code_prefix IS NULL OR code_prefix ~ '^[A-Z0-9]{1,8}$');
