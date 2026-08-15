-- 总账 AUTO 凭证头补齐来源单据 UUID。
-- voucher_no 是生成时的可读单号快照；运行时关联、幂等重建和反写统一使用
-- (source_type, source_doc_id)，多态来源不建立物理外键。

ALTER TABLE gl_vouchers
    ADD COLUMN source_doc_id UUID;

COMMENT ON COLUMN gl_vouchers.source_doc_id IS
    'AUTO 凭证来源业务单据 UUID 真源（多态，不建 FK）；voucher_no 仅为生成时单号快照';

-- 只在现有有效分录能够完整且唯一证明凭证归属时回填。以下任一情况均不猜测：
--   1. 凭证没有有效分录；
--   2. 任一有效分录缺少 source_doc_id；
--   3. 有效分录指向多个来源 UUID；
--   4. 分录来源类型与凭证投影类型不匹配；
--   5. 同一 (source_type, source_doc_id) 被多个凭证占用。
WITH proven_entry_source AS (
    SELECT voucher.id AS voucher_id,
           voucher.source_type,
           MIN(entry.source_doc_id::text)::UUID AS source_doc_id
    FROM gl_vouchers voucher
    JOIN gl_entries entry
      ON entry.voucher_id = voucher.id
     AND COALESCE(entry.is_deleted, FALSE) = FALSE
    WHERE voucher.source = 'AUTO'
      AND voucher.source_type IN (
          'AR_POST', 'AP_POST', 'RECEIPT', 'PAYMENT',
          'EXPENSE', 'INCOME', 'COST_CARRY', 'BANK_TRANSFER'
      )
      AND COALESCE(voucher.is_deleted, FALSE) = FALSE
      AND (
          (voucher.source_type = 'AR_POST'
              AND entry.source_doc_type IN ('SALES_SHIPMENT', 'SALES_RETURN'))
          OR (voucher.source_type = 'AP_POST'
              AND entry.source_doc_type IN (
                  'PURCHASE_RECEIPT', 'PURCHASE_RETURN', 'SUBCONTRACT_RECEIPT'
              ))
          OR (voucher.source_type NOT IN ('AR_POST', 'AP_POST')
              AND entry.source_doc_type = voucher.source_type)
      )
    GROUP BY voucher.id, voucher.source_type
    HAVING COUNT(*) > 0
       AND COUNT(entry.source_doc_id) = COUNT(*)
       AND COUNT(DISTINCT entry.source_doc_id) = 1
       AND COUNT(*) = (
           SELECT COUNT(*)
           FROM gl_entries all_entry
           WHERE all_entry.voucher_id = voucher.id
             AND COALESCE(all_entry.is_deleted, FALSE) = FALSE
       )
), uniquely_owned_source AS (
    SELECT proven.*
    FROM proven_entry_source proven
    JOIN (
        SELECT source_type, source_doc_id
        FROM proven_entry_source
        GROUP BY source_type, source_doc_id
        HAVING COUNT(*) = 1
    ) unique_source
      ON unique_source.source_type = proven.source_type
     AND unique_source.source_doc_id = proven.source_doc_id
)
UPDATE gl_vouchers voucher
SET source_doc_id = proven.source_doc_id
FROM uniquely_owned_source proven
WHERE voucher.id = proven.voucher_id
  AND voucher.source_doc_id IS NULL;

CREATE INDEX idx_gl_vouchers_source_doc
    ON gl_vouchers(source_type, source_doc_id)
    WHERE source_doc_id IS NOT NULL;

-- 一个有效 AUTO 投影只能对应一个来源业务单据；历史无法证明归属的 NULL 行不参与。
CREATE UNIQUE INDEX ux_gl_vouchers_active_auto_source_doc
    ON gl_vouchers(source_type, source_doc_id)
    WHERE source = 'AUTO'
      AND status = 1
      AND COALESCE(is_deleted, FALSE) = FALSE
      AND source_doc_id IS NOT NULL;

-- NOT VALID 保留历史不确定行，但 PostgreSQL 会立即约束 V266 之后的新写入/更新。
-- 这样既不凭自由文本猜历史，也不允许在线路径继续产生无 UUID 的 AUTO 凭证。
ALTER TABLE gl_vouchers
    ADD CONSTRAINT gl_vouchers_regenerated_source_doc_required_chk
    CHECK (
        source <> 'AUTO'
        OR source_type NOT IN (
            'AR_POST', 'AP_POST', 'RECEIPT', 'PAYMENT',
            'EXPENSE', 'INCOME', 'COST_CARRY', 'BANK_TRANSFER'
        )
        OR source_doc_id IS NOT NULL
    ) NOT VALID;
