-- =====================================================================
-- V282：员工敏感 PII 扩展加密列 + 生日月日派生列
-- =====================================================================
-- 背景：户籍/居住地址、邮箱、出生日期、婚姻/政治面貌、办公电话 此前在 employees 主表明文。
--   现迁入 employee_sensitive（pgcrypto 加密；主密钥 UTEN_PGP_MASTER_KEY 由应用环境注入，
--   当前不是外部 KMS envelope）。仅取得数据库副本且未同时取得应用密钥时不能直接解密这些列。
--   birth_date 加密后，生日祝福改用 birth_month_day（不含年份、低敏但仍属于个人属性）。
--   数据回填由应用侧 EmployeePiiExtraBackfillRunner 在启动期完成（Flyway 拿不到 JVM 主密钥）。
--   runner 全局串行、小批逐行锁定、核对/条件写密文后清空原 7 列；缺 sensitive 行或残留非零会阻断启动。
-- 幂等：IF NOT EXISTS；自包含，与 V03 不交叉（只加列，不改既有列）。
-- =====================================================================

ALTER TABLE employee_sensitive
    ADD COLUMN IF NOT EXISTS huji_address_enc     TEXT,
    ADD COLUMN IF NOT EXISTS residence_address_enc TEXT,
    ADD COLUMN IF NOT EXISTS email_enc            TEXT,
    ADD COLUMN IF NOT EXISTS birth_date_enc       TEXT,
    ADD COLUMN IF NOT EXISTS marital_status_enc   TEXT,
    ADD COLUMN IF NOT EXISTS political_status_enc TEXT,
    ADD COLUMN IF NOT EXISTS office_phone_enc     TEXT;

ALTER TABLE employees
    ADD COLUMN IF NOT EXISTS birth_month_day VARCHAR(5);

COMMENT ON COLUMN employees.birth_month_day IS '生日月日 MM-DD（不含年份、低敏但仍属个人属性），供生日祝福匹配；由 birth_date 派生';

-- The seven legacy plaintext columns remain physically present for controlled
-- one-time imports and forward recovery, but ordinary application/SQL writes
-- must never populate or clear them.  V282's JVM runner and the reviewed HR
-- legacy-import scripts use separate, transaction-local capability markers.
CREATE OR REPLACE FUNCTION fn_guard_employee_pii_extra_plaintext()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_authorized BOOLEAN :=
        COALESCE(current_setting('app.employee_pii_extra_backfill', true) = 'v1', FALSE)
        OR COALESCE(current_setting('app.employee_pii_extra_legacy_import', true) = 'v1', FALSE);
    v_changed BOOLEAN;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_changed := NEW.huji_address IS NOT NULL
            OR NEW.residence_address IS NOT NULL
            OR NEW.email IS NOT NULL
            OR NEW.birth_date IS NOT NULL
            OR NEW.marital_status IS NOT NULL
            OR NEW.political_status IS NOT NULL
            OR NEW.office_phone IS NOT NULL;
    ELSE
        v_changed := NEW.huji_address IS DISTINCT FROM OLD.huji_address
            OR NEW.residence_address IS DISTINCT FROM OLD.residence_address
            OR NEW.email IS DISTINCT FROM OLD.email
            OR NEW.birth_date IS DISTINCT FROM OLD.birth_date
            OR NEW.marital_status IS DISTINCT FROM OLD.marital_status
            OR NEW.political_status IS DISTINCT FROM OLD.political_status
            OR NEW.office_phone IS DISTINCT FROM OLD.office_phone;
    END IF;

    IF v_changed AND NOT v_authorized THEN
        RAISE EXCEPTION
            'employees legacy PII plaintext write requires V282 migration capability (employee %)',
            NEW.id;
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS employee_pii_extra_plaintext_insert_guard ON employees;
CREATE TRIGGER employee_pii_extra_plaintext_insert_guard
BEFORE INSERT ON employees
FOR EACH ROW
EXECUTE FUNCTION fn_guard_employee_pii_extra_plaintext();

DROP TRIGGER IF EXISTS employee_pii_extra_plaintext_update_guard ON employees;
CREATE TRIGGER employee_pii_extra_plaintext_update_guard
BEFORE UPDATE OF huji_address, residence_address, email, birth_date,
                 marital_status, political_status, office_phone
ON employees
FOR EACH ROW
EXECUTE FUNCTION fn_guard_employee_pii_extra_plaintext();

COMMENT ON FUNCTION fn_guard_employee_pii_extra_plaintext() IS
    'V282 fail-closed guard: only explicit backfill or reviewed legacy-import transactions may change the seven employees plaintext PII columns';
