-- Repair finance placeholder parties whose Chinese literals were replaced with
-- ASCII question marks by a legacy Windows code-page execution path.
-- Only untouched LEGACY-FIN placeholders are changed; manually completed
-- master records are preserved.

ALTER TABLE clients DROP CONSTRAINT IF EXISTS clients_status_chk;

UPDATE clients
SET name = CASE
        WHEN name ~ '^[?]+$'
            THEN U&'\94B1\6D41\5386\53F2\5BA2\6237\FF08\539FID '
                 || legacy_id::text || U&'\FF09'
        ELSE name
    END,
    status = U&'\7981\7528',
    remark = CASE
        WHEN remark IS NULL OR remark ~ '^[?]+$'
            THEN U&'\5386\53F2\94B1\6D41\81EA\52A8\8865\5F55\FF0C\771F\5B9E\4E3B\6863\7F3A\5931\FF0C\52FF\7528\4E8E\65B0\5355'
        ELSE remark
    END,
    updated_at = CURRENT_TIMESTAMP
WHERE code = 'LEGACY-FIN-CL-' || legacy_id::text
  AND is_deleted = FALSE
  AND (name ~ '^[?]+$' OR status ~ '^[?]+$' OR remark ~ '^[?]+$');

ALTER TABLE clients
    ADD CONSTRAINT clients_status_chk
    CHECK (status IS NULL OR status IN (U&'\4F7F\7528', U&'\7981\7528'))
    NOT VALID;
ALTER TABLE clients VALIDATE CONSTRAINT clients_status_chk;

ALTER TABLE suppliers DROP CONSTRAINT IF EXISTS suppliers_status_chk;

UPDATE suppliers
SET name = CASE
        WHEN name ~ '^[?]+$'
            THEN U&'\94B1\6D41\5386\53F2\4F9B\5E94\5546\FF08\539FID '
                 || legacy_id::text || U&'\FF09'
        ELSE name
    END,
    status = U&'\7981\7528',
    remark = CASE
        WHEN remark IS NULL OR remark ~ '^[?]+$'
            THEN U&'\5386\53F2\94B1\6D41\81EA\52A8\8865\5F55\FF0C\771F\5B9E\4E3B\6863\7F3A\5931\FF0C\52FF\7528\4E8E\65B0\5355'
        ELSE remark
    END,
    updated_at = CURRENT_TIMESTAMP
WHERE code = 'LEGACY-FIN-SP-' || legacy_id::text
  AND is_deleted = FALSE
  AND (name ~ '^[?]+$' OR status ~ '^[?]+$' OR remark ~ '^[?]+$');

ALTER TABLE suppliers
    ADD CONSTRAINT suppliers_status_chk
    CHECK (status IS NULL OR status IN (U&'\4F7F\7528', U&'\7981\7528'))
    NOT VALID;
ALTER TABLE suppliers VALIDATE CONSTRAINT suppliers_status_chk;
