-- =====================================================================
-- V224：通知庆典/互动（回执 + 祝福 + 庆典通知字段 + 自动发布种子）
-- =====================================================================
-- 背景：原通知仅单向广播 + 每用户已读/删除状态。本次按类型驱动互动：
--   * acknowledge（点击收到）：announcement/policy/system/urgent/benefit
--   * bless     （送上祝福）：birthday/anniversary/wedding/newborn（本次新增的类型）
--   * none：task/approval/workflow（保持原样）
-- 并支持每日定时扫描在职员工生日/入职纪念日，自动发布庆典通知（toggle 在 system_settings）。
-- 安全/隐私：庆典通知只写姓名快照 subject_name 与节日标签 event_label，
--            不写入 birth_date/hire_date 原值；调度器内部按月日匹配后丢弃原值。
-- =====================================================================

-- notices：互动模式 + 庆典对象快照 ---------------------------------------------------
ALTER TABLE notices ADD COLUMN subject_employee_id UUID    NULL REFERENCES employees(id) ON DELETE SET NULL;
ALTER TABLE notices ADD COLUMN subject_name        VARCHAR(100);
ALTER TABLE notices ADD COLUMN event_label         VARCHAR(100);
ALTER TABLE notices ADD COLUMN blessing_templates  JSONB;  -- 发布时预设的祝福语模板（数组）
ALTER TABLE notices ADD COLUMN interaction_mode    VARCHAR(20) NOT NULL DEFAULT 'none';
ALTER TABLE notices ADD CONSTRAINT ck_notices_interaction_mode
    CHECK (interaction_mode IN ('none','acknowledge','bless'));

COMMENT ON COLUMN notices.interaction_mode IS '互动模式：none=无 / acknowledge=回执 / bless=祝福';
COMMENT ON COLUMN notices.subject_employee_id IS '庆典对象员工 ID（仅 bless 类通知）';
COMMENT ON COLUMN notices.subject_name IS '庆典对象姓名快照（发布后改名不回溯）';
COMMENT ON COLUMN notices.event_label IS '节日标签快照（如 生日快乐 / 入职5周年）';
COMMENT ON COLUMN notices.blessing_templates IS '发布时预设的祝福语模板（字符串数组）';

-- 按 type 回填已有通知的 interaction_mode
UPDATE notices SET interaction_mode = 'acknowledge'
    WHERE interaction_mode = 'none'
      AND type IN ('announcement','policy','system','urgent','benefit');
UPDATE notices SET interaction_mode = 'none'
    WHERE type IN ('task','approval','workflow');

-- 调度器按 (subject_employee_id, type, 当年) 去重的查询索引
CREATE INDEX idx_notices_subject_type ON notices(subject_employee_id, type);

-- 回执（每用户幂等：一人对一条通知只算一次）-----------------------------------------
CREATE TABLE notice_acknowledgments (
    notice_id UUID NOT NULL REFERENCES notices(id) ON DELETE CASCADE,
    user_id   UUID NOT NULL REFERENCES users(id)   ON DELETE CASCADE,
    acked_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (notice_id, user_id)
);
CREATE INDEX idx_notice_acknowledgments_notice ON notice_acknowledgments(notice_id);

COMMENT ON TABLE notice_acknowledgments IS '通知回执（一人一条仅一次；主键保证幂等）';

-- 祝福（每用户对一条通知至多一条，可改可撤回）---------------------------------------
CREATE TABLE notice_blessings (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    notice_id   UUID NOT NULL REFERENCES notices(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES users(id)   ON DELETE CASCADE,
    sender_name VARCHAR(100) NOT NULL,                -- 祝福人姓名快照（改名不回溯）
    content     TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by  UUID,
    updated_by  UUID,
    UNIQUE (notice_id, user_id)
);
CREATE INDEX idx_notice_blessings_notice ON notice_blessings(notice_id);

COMMENT ON TABLE notice_blessings IS '通知祝福（一人一条；UNIQUE(notice_id,user_id) 保证 upsert 语义）';

-- 系统设置：庆典自动发布开关 ---------------------------------------------------------
-- value_type 沿用 V72 词汇（int/long/string/bool）；category 沿用 'business'。
INSERT INTO system_settings (key, value, value_type, category, label, description, unit, sort_order) VALUES
    ('celebration.auto_enabled',  'true',                'bool',   'business', '庆典通知自动发布',
     '每日 08:00 自动扫描在职员工生日/入职纪念日并发布庆典通知（关闭则完全停发）',
     NULL, 320),
    ('celebration.auto_types',    'birthday,anniversary','string', 'business', '自动发布的庆典类型',
     '逗号分隔，可选值：birthday/anniversary/wedding/newborn（仅 birthday/anniversary 支持自动扫描）',
     NULL, 321),
    ('celebration.publisher_name','公司',                'string', 'business', '自动庆典通知署名',
     '自动发布的庆典通知 publisher 字段（如「公司」/「人力资源部」）',
     NULL, 322)
ON CONFLICT (key) DO NOTHING;
