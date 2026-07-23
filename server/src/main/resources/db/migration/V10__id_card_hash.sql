-- 身份证号查重：HMAC 列 + 部分唯一索引。
-- 明文身份证已加密、无法直接唯一索引；存 HMAC(UTEN_HMAC_KEY, 全号) 用于确定性查重。
-- 部分索引（WHERE id_card_hash IS NOT NULL）：非身份证证件的员工该列为 NULL，不冲突。
ALTER TABLE employee_sensitive ADD COLUMN IF NOT EXISTS id_card_hash TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS uk_employee_sensitive_id_card_hash
    ON employee_sensitive (id_card_hash)
    WHERE id_card_hash IS NOT NULL;

COMMENT ON COLUMN employee_sensitive.id_card_hash IS '身份证号 HMAC（HMAC-SHA256(UTEN_HMAC_KEY, 全号)），用于查重；不可逆';
