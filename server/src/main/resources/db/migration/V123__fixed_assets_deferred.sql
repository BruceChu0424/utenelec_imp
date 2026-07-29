-- V123 · 固定资产折旧 + 长期待摊摊销（C5）。
-- 科目增补（auto_created=true 标记系统种子，用户可在字典维护改名）：
--   /152/ 累计折旧（ACCOUNT，贷方备抵）/ 043 一级子 折旧费、摊销费（EXPENSE）。
-- 计提过账：借 资产费用科目（默认 折旧费/摊销费）/ 贷 /152/ 或 /139/ 待摊费用；fa/da_log 防重复计提。

-- 科目种子（幂等：path 不存在才插）
INSERT INTO payment_styles (code, name, category, level, sort_order, path, is_departmental, is_receipt, is_payment, status, auto_created)
SELECT '152', '累计折旧', 'ACCOUNT', 0, 52, '/152/', false, true, false, '使用', true
WHERE NOT EXISTS (SELECT 1 FROM payment_styles WHERE path='/152/');
INSERT INTO payment_styles (code, name, category, parent_id, level, sort_order, path, is_departmental, is_receipt, is_payment, status, auto_created)
SELECT '043', '折旧费', 'EXPENSE', p.id, 1, 80, '/043/043/', false, false, true, '使用', true
FROM payment_styles p WHERE p.path='/043/'
  AND NOT EXISTS (SELECT 1 FROM payment_styles WHERE path='/043/043/' AND name='折旧费' AND category='EXPENSE');
INSERT INTO payment_styles (code, name, category, parent_id, level, sort_order, path, is_departmental, is_receipt, is_payment, status, auto_created)
SELECT '043', '摊销费', 'EXPENSE', p.id, 1, 81, '/043/043/', false, false, true, '使用', true
FROM payment_styles p WHERE p.path='/043/'
  AND NOT EXISTS (SELECT 1 FROM payment_styles WHERE path='/043/043/' AND name='摊销费' AND category='EXPENSE');

-- 固定资产
CREATE TABLE fixed_assets (
    id              uuid        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    code            text        NOT NULL UNIQUE,          -- 资产编号
    name            text        NOT NULL,                 -- 资产名称
    department_id   uuid REFERENCES departments(id),
    expense_style_id uuid REFERENCES payment_styles(id),  -- 折旧费用科目（默认 折旧费；可改 制造/管理口径）
    original_value  numeric(18,4) NOT NULL,               -- 原值
    salvage_rate    numeric(5,4)  NOT NULL DEFAULT 0.05,  -- 残值率
    useful_months   integer     NOT NULL,                 -- 使用年限（月）
    start_period    char(7)     NOT NULL,                 -- 开始折旧期间 YYYY-MM
    status          text        NOT NULL DEFAULT '在用',   -- 在用/停用/清理
    remark          text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid,
    updated_by      uuid,
    is_deleted      boolean     NOT NULL DEFAULT false,
    deleted_at      timestamptz
);

-- 长期待摊
CREATE TABLE deferred_expenses (
    id              uuid        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    code            text        NOT NULL UNIQUE,
    name            text        NOT NULL,
    expense_style_id uuid REFERENCES payment_styles(id),  -- 摊销费用科目（默认 摊销费）
    total_amount    numeric(18,4) NOT NULL,               -- 待摊总额
    useful_months   integer     NOT NULL,                 -- 摊销月数
    start_period    char(7)     NOT NULL,                 -- 开始摊销期间
    status          text        NOT NULL DEFAULT '摊销中', -- 摊销中/已摊完/停用
    remark          text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid,
    updated_by      uuid,
    is_deleted      boolean     NOT NULL DEFAULT false,
    deleted_at      timestamptz
);

-- 计提日志（asset+period 唯一防重复；voucher_id 回链总账）
CREATE TABLE fa_depreciation_log (
    id          uuid      NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    asset_id    uuid      NOT NULL REFERENCES fixed_assets(id) ON DELETE CASCADE,
    period      char(7)   NOT NULL,
    amount      numeric(18,4) NOT NULL,
    voucher_id  uuid REFERENCES gl_vouchers(id),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,
    updated_by  uuid,
    is_deleted  boolean   NOT NULL DEFAULT false,
    deleted_at  timestamptz,
    UNIQUE (asset_id, period)
);
CREATE INDEX idx_fadl_period ON fa_depreciation_log (period);

CREATE TABLE da_amortization_log (
    id          uuid      NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    deferred_id uuid      NOT NULL REFERENCES deferred_expenses(id) ON DELETE CASCADE,
    period      char(7)   NOT NULL,
    amount      numeric(18,4) NOT NULL,
    voucher_id  uuid REFERENCES gl_vouchers(id),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,
    updated_by  uuid,
    is_deleted  boolean   NOT NULL DEFAULT false,
    deleted_at  timestamptz,
    UNIQUE (deferred_id, period)
);
CREATE INDEX idx_daml_period ON da_amortization_log (period);
