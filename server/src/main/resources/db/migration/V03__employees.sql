-- 员工档案：核心身份 + 组织 + 用工（不含加密 PII）
CREATE TABLE employees (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code            TEXT NOT NULL UNIQUE,                 -- 工号
    full_name       TEXT NOT NULL,
    gender          TEXT CHECK (gender IN ('male','female')),
    id_type         TEXT NOT NULL CHECK (id_type IN ('身份证','护照','港澳台通行证','其他')),
    birth_date      DATE,
    ethnicity       TEXT,
    political_status TEXT,
    marital_status TEXT,
    huji_address    TEXT,
    residence_address TEXT,
    department_id   UUID NOT NULL REFERENCES departments(id) ON DELETE RESTRICT,
    position_id     UUID REFERENCES positions(id) ON DELETE SET NULL,
    supervisor_id   UUID REFERENCES employees(id) ON DELETE SET NULL,
    hire_date       DATE NOT NULL,
    confirmed_at    DATE,                                 -- 转正日期（转正事件写入；≠试用期结束）
    status          TEXT NOT NULL CHECK (status IN ('active','probation','onLeave','resigned')),
    employment_type TEXT NOT NULL CHECK (employment_type IN ('regular','dispatch','intern','outsource')),
    work_location   TEXT,
    seat_no         TEXT,
    attendance_group TEXT,
    office_phone    TEXT,
    email           TEXT,
    paper_archive_no TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ
);
CREATE INDEX idx_employees_department ON employees(department_id);
CREATE INDEX idx_employees_supervisor ON employees(supervisor_id);
CREATE INDEX idx_employees_status     ON employees(status);
CREATE INDEX idx_employees_active     ON employees(is_deleted);
COMMENT ON TABLE  employees IS '员工档案主表（核心身份+组织+用工）';
COMMENT ON COLUMN employees.confirmed_at IS '转正日期（转正事件触发写入；≠试用期结束，后者由 hire_date+contract.probation_months 派生）';
COMMENT ON COLUMN employees.supervisor_id IS '直属上级（指向 employees.id，自引用）';

-- 补加 departments.manager_id → employees 的外键（V02 留的前向引用）
ALTER TABLE departments
    ADD CONSTRAINT fk_departments_manager
    FOREIGN KEY (manager_id) REFERENCES employees(id) ON DELETE SET NULL;

-- 员工敏感 PII（全部 pgcrypto 加密，隔离加密面；仅 hr+admin 可见明文）
CREATE TABLE employee_sensitive (
    employee_id      UUID PRIMARY KEY REFERENCES employees(id) ON DELETE CASCADE,
    id_card_enc      TEXT NOT NULL,        -- pgp_sym_encrypt(身份证全号, key)
    id_card_last4    TEXT,                 -- 明文尾4（免全解密展示，非敏感）
    phone_enc        TEXT NOT NULL,        -- pgp_sym_encrypt(手机, key)
    phone_hash       TEXT,                 -- HMAC-SHA256（可选按手机查）
    bank_account_enc TEXT,                 -- pgp_sym_encrypt(银行卡号, key)
    bank_branch_enc  TEXT,                 -- pgp_sym_encrypt(开户银行及支行, key)
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID
);
COMMENT ON TABLE employee_sensitive IS '员工敏感 PII（pgcrypto 加密：身份证/手机/银行）。仅 hr+admin 可见明文';

-- 薪资数字（pgcrypto 加密，单独表便于工资聚合与按角色隔离；仅 hr+finance+admin 可见）
CREATE TABLE employee_compensation (
    employee_id              UUID PRIMARY KEY REFERENCES employees(id) ON DELETE CASCADE,
    base_salary_enc          TEXT,   -- 基本工资
    perf_salary_enc          TEXT,   -- 绩效工资/岗位补贴
    social_insurance_base_enc TEXT,  -- 社保缴纳基数
    housing_fund_base_enc    TEXT,   -- 公积金缴纳基数
    allowance_standard_enc   TEXT,   -- 补贴标准
    social_insurance_location TEXT,  -- 社保缴纳地（非敏感，明文）
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID
);
COMMENT ON TABLE employee_compensation IS '薪资数字（pgcrypto 加密）。仅 hr+finance+admin 可见';

-- 紧急联系人（1:N）
CREATE TABLE emergency_contacts (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id  UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    name         TEXT NOT NULL,
    phone_enc    TEXT,
    relationship TEXT,
    sort_order   INT  NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID
);
CREATE INDEX idx_emergency_contacts_employee ON emergency_contacts(employee_id);

-- 劳动合同（1:N；驱动续签次数 = count(*)，当前合同 = 最新 sign_order）
CREATE TABLE employee_contracts (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id      UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    contract_type    TEXT NOT NULL CHECK (contract_type IN ('fixed','open','task','intern')),
    start_date       DATE NOT NULL,
    end_date         DATE,
    probation_months INT,                  -- 试用期月数（用于派生试用期结束日）
    sign_order       INT  NOT NULL DEFAULT 1,  -- 签订序号 1,2,3…
    remark           TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID
);
CREATE INDEX idx_contracts_employee ON employee_contracts(employee_id);
COMMENT ON COLUMN employee_contracts.sign_order IS '签订序号 1,2,3…；续签次数 = count(*)，当前合同 = max(sign_order)';

-- 学历（1:N，可选）
CREATE TABLE employee_education (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    degree      TEXT,
    school      TEXT,
    major       TEXT,
    start_date  DATE,
    end_date    DATE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID
);
CREATE INDEX idx_education_employee ON employee_education(employee_id);

-- 技能/资格证书、健康证明（1:N，可选）
CREATE TABLE employee_credentials (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    type        TEXT,        -- 技能证书/健康证明/…
    name        TEXT,
    cert_no     TEXT,
    issued_at   DATE,
    expires_at  DATE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID
);
CREATE INDEX idx_credentials_employee ON employee_credentials(employee_id);

-- 任职轨迹（入职/调岗/离职；按 event_date 倒序即时间线）
CREATE TABLE employment_history (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id      UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    event_type       TEXT NOT NULL CHECK (event_type IN ('onboard','transfer','resign')),
    from_dept_id     UUID REFERENCES departments(id) ON DELETE SET NULL,
    to_dept_id       UUID REFERENCES departments(id) ON DELETE SET NULL,
    from_position_id UUID REFERENCES positions(id) ON DELETE SET NULL,
    to_position_id   UUID REFERENCES positions(id) ON DELETE SET NULL,
    event_date       DATE NOT NULL,
    remark           TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID
);
CREATE INDEX idx_history_employee ON employment_history(employee_id);
COMMENT ON TABLE employment_history IS '任职轨迹（入职/调岗/离职）';
