-- Follow-up for V148. V148 has already been applied in deployed databases and
-- must remain byte-for-byte immutable so Flyway can validate its checksum.
--
-- Some placeholder parties use a LEGACY-FIN code suffix that is not identical
-- to legacy_id. Repair those untouched placeholders by the reserved code
-- prefix without rewriting manually completed master data.

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
WHERE code LIKE 'LEGACY-FIN-CL-%'
  AND legacy_id IS NOT NULL
  AND is_deleted = FALSE
  AND (name ~ '^[?]+$' OR status ~ '^[?]+$' OR remark ~ '^[?]+$');

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
WHERE code LIKE 'LEGACY-FIN-SP-%'
  AND legacy_id IS NOT NULL
  AND is_deleted = FALSE
  AND (name ~ '^[?]+$' OR status ~ '^[?]+$' OR remark ~ '^[?]+$');
