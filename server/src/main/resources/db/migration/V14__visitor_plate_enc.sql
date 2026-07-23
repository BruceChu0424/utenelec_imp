-- H2：访客车牌号加密存储（plate_no 明文 → plate_no_enc 密文）。
-- 车牌号可识别车主，属 PII；与员工身份证/手机同等级加密。
ALTER TABLE visitor_applications ADD COLUMN IF NOT EXISTS plate_no_enc TEXT;
COMMENT ON COLUMN visitor_applications.plate_no_enc IS '车牌号密文（pgcrypto 加密）；旧 plate_no 列保留兼容，后续清理';
