-- 访客申请增加 passcode：6位短码，二维码无法扫描时保安手动输入核验（降级方案）。
ALTER TABLE visitor_applications ADD COLUMN IF NOT EXISTS passcode TEXT;
CREATE INDEX IF NOT EXISTS idx_visitor_app_passcode ON visitor_applications(passcode);
COMMENT ON COLUMN visitor_applications.passcode IS 'HR 批准后生成的6位短码，保安手动输入核验（二维码扫不了时）';
