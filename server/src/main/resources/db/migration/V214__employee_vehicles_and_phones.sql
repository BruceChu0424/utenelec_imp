-- =====================================================================
-- V211：员工车辆 + 备用手机号（ADR-021 §二）
-- - employee_vehicles：车牌明文 + 规范化索引——「按车牌找人」是门岗/行政刚需；
--   全部字段非必填，查阅走 employee:view。
-- - employee_phones：备用手机号 pgcrypto 加密 + HMAC（与主手机同口径），
--   不参与登录；展示按 employee:pii:view 明文、否则掩码。
-- =====================================================================

CREATE TABLE employee_vehicles (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id  UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    plate_no     TEXT NOT NULL,                 -- 原始录入（展示用）
    plate_norm   TEXT NOT NULL,                 -- 规范化：大写、去空白（查重/搜索用）
    vehicle_type TEXT,                          -- 轿车/SUV/电动车/摩托车…（自由文本，非必填）
    brand_model  TEXT,                          -- 品牌型号（非必填）
    color        TEXT,                          -- 颜色（非必填）
    remark       TEXT,
    sort_order   INT  NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    CONSTRAINT employee_vehicles_plate_len CHECK (char_length(plate_norm) BETWEEN 7 AND 8)
);
CREATE UNIQUE INDEX uq_employee_vehicles_plate ON employee_vehicles (employee_id, plate_norm);
CREATE INDEX idx_employee_vehicles_norm ON employee_vehicles (plate_norm);
COMMENT ON TABLE employee_vehicles IS '员工车辆（1:N，全部非必填）；plate_norm=大写去空白，7-8位含新能源车牌';

CREATE TABLE employee_phones (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id  UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    label        TEXT NOT NULL DEFAULT '备用',  -- 本人/家属/备用…（自由文本）
    phone_enc    TEXT NOT NULL,                 -- pgp_sym_encrypt(手机号, key)，与主手机同口径
    phone_hash   TEXT,                          -- HMAC-SHA256（员工内查重）
    sort_order   INT  NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID
);
CREATE UNIQUE INDEX uq_employee_phones_hash ON employee_phones (employee_id, phone_hash);
CREATE INDEX idx_employee_phones_employee ON employee_phones (employee_id);
COMMENT ON TABLE employee_phones IS '员工备用手机号（1:N，加密存储，不参与登录）';

-- 通用审计触发器（fn_audit 见 V05）
DROP TRIGGER IF EXISTS trg_audit_employee_vehicles ON employee_vehicles;
CREATE TRIGGER trg_audit_employee_vehicles
    AFTER INSERT OR UPDATE OR DELETE ON employee_vehicles
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

DROP TRIGGER IF EXISTS trg_audit_employee_phones ON employee_phones;
CREATE TRIGGER trg_audit_employee_phones
    AFTER INSERT OR UPDATE OR DELETE ON employee_phones
    FOR EACH ROW EXECUTE FUNCTION fn_audit();
