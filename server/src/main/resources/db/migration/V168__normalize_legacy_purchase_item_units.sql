-- Normalize only deterministic legacy purchase-line unit omissions.
--
-- Legacy rows can carry UnitID = 0 while URate = 1. When the referenced goods
-- has a resolvable base unit, that combination means the stored quantity is
-- already in the base unit and can be repaired without inventing a conversion.
--
-- Ambiguous rows stay unchanged:
--   * the source/document unit is absent and the rate is not 1; or
--   * the goods base unit cannot be resolved.
-- MRP remains fail-closed for any such unfinished purchase order line.

UPDATE purchase_request_items i
SET unit_id = u.id,
    unit_rate = 1,
    updated_at = CURRENT_TIMESTAMP
FROM goods g
JOIN units u
  ON u.legacy_id = g.unit_legacy_id
 AND u.is_deleted = FALSE
WHERE i.goods_id = g.id
  AND i.legacy_id IS NOT NULL
  AND i.unit_id IS NULL
  AND COALESCE(i.unit_rate, 1) = 1
  AND g.is_deleted = FALSE;

UPDATE purchase_order_items i
SET unit_id = u.id,
    unit_rate = 1,
    updated_at = CURRENT_TIMESTAMP
FROM goods g
JOIN units u
  ON u.legacy_id = g.unit_legacy_id
 AND u.is_deleted = FALSE
WHERE i.goods_id = g.id
  AND i.legacy_id IS NOT NULL
  AND i.unit_id IS NULL
  AND COALESCE(i.unit_rate, 1) = 1
  AND g.is_deleted = FALSE;

UPDATE purchase_receipt_items i
SET unit_id = u.id,
    unit_rate = 1,
    updated_at = CURRENT_TIMESTAMP
FROM goods g
JOIN units u
  ON u.legacy_id = g.unit_legacy_id
 AND u.is_deleted = FALSE
WHERE i.goods_id = g.id
  AND i.legacy_id IS NOT NULL
  AND i.unit_id IS NULL
  AND COALESCE(i.unit_rate, 1) = 1
  AND g.is_deleted = FALSE;

UPDATE purchase_return_items i
SET unit_id = u.id,
    unit_rate = 1,
    updated_at = CURRENT_TIMESTAMP
FROM goods g
JOIN units u
  ON u.legacy_id = g.unit_legacy_id
 AND u.is_deleted = FALSE
WHERE i.goods_id = g.id
  AND i.legacy_id IS NOT NULL
  AND i.unit_id IS NULL
  AND COALESCE(i.unit_rate, 1) = 1
  AND g.is_deleted = FALSE;
