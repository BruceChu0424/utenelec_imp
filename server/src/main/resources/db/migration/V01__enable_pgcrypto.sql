-- pgcrypto：提供 gen_random_uuid() 与 pgp_sym_encrypt/decrypt（PII 字段级加密）
CREATE EXTENSION IF NOT EXISTS pgcrypto;
COMMENT ON EXTENSION pgcrypto IS 'Uten IMP：UUID 生成 + 身份证/手机/银行/薪资的字段级加密';
