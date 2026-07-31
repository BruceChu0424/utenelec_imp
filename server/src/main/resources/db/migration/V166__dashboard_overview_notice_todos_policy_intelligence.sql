-- V166：部门化今日概览、通知待办和可核验政策情报。
--
-- 安全边界：
--   * 财务余额等敏感指标不物化到本表，由 Dashboard 查询服务按当前权限实时返回；
--   * 人工通知的待办完成状态按接收人保存在 notice_user_states；
--   * 政策情报只保存官方来源原文链接和基于原文的摘要，AI 不作为事实来源。

ALTER TABLE notices
    ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'NORMAL',
    ADD COLUMN IF NOT EXISTS action_route VARCHAR(500),
    ADD COLUMN IF NOT EXISTS due_at TIMESTAMPTZ;

ALTER TABLE notices
    DROP CONSTRAINT IF EXISTS ck_notices_kind;

ALTER TABLE notices
    ADD CONSTRAINT ck_notices_kind
    CHECK (kind IN ('NORMAL', 'TODO'));

ALTER TABLE notice_user_states
    ADD COLUMN IF NOT EXISTS task_completed_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_notices_todo_due_published
    ON notices(kind, due_at, published_at DESC)
    WHERE kind = 'TODO';

CREATE INDEX IF NOT EXISTS idx_notice_user_states_todo_completion
    ON notice_user_states(user_id, task_completed_at, notice_id);

-- 旧 account:view / ar_ap_ledger:view 是全员基础查询权限，不能作为资金汇总的
-- 敏感边界。新增独立权限，默认只授予财税部；管理端仍可按部门或个人覆盖。
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('dashboard:finance-sensitive:view', '查看工作台财务敏感指标', '工作台', 10)
ON CONFLICT (code) DO NOTHING;

INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d, permissions p
WHERE d.code = 'DEPT_FIN'
  AND p.code = 'dashboard:finance-sensitive:view'
ON CONFLICT DO NOTHING;

CREATE TABLE official_policy_briefs (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title          TEXT NOT NULL,
    summary        TEXT NOT NULL,
    category       TEXT NOT NULL,
    audience_tags  JSONB NOT NULL DEFAULT '[]',
    source_name    TEXT NOT NULL,
    source_url     TEXT NOT NULL UNIQUE,
    source_host    TEXT NOT NULL,
    published_on   DATE NOT NULL,
    valid_until    DATE,
    status         TEXT NOT NULL DEFAULT 'ACTIVE',
    source_hash    VARCHAR(64),
    ai_model       TEXT,
    captured_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_official_policy_category
        CHECK (category IN ('TAX', 'SUBSIDY', 'EXPORT', 'INSPECTION', 'SAFETY', 'QUALITY', 'OTHER')),
    CONSTRAINT ck_official_policy_status
        CHECK (status IN ('ACTIVE', 'EXPIRED', 'ARCHIVED')),
    CONSTRAINT ck_official_policy_audience_json
        CHECK (jsonb_typeof(audience_tags) = 'array'),
    CONSTRAINT ck_official_policy_source_https
        CHECK (source_url LIKE 'https://%')
);

CREATE INDEX idx_official_policy_visible
    ON official_policy_briefs(status, published_on DESC);

COMMENT ON TABLE official_policy_briefs IS
    '官方政策与监管动态：原文是事实来源，DeepSeek 仅对已抓取原文做结构化摘要';
COMMENT ON COLUMN official_policy_briefs.audience_tags IS
    'FINANCE/GM/SALES/PRODUCTION/PMC/QA/HR/SECURITY/ALL 等部门化展示标签';
COMMENT ON COLUMN official_policy_briefs.ai_model IS
    '生成摘要的模型；NULL 表示人工核验的初始化摘要';

-- 2026-07-31 初始化快照：均来自官方站点，后续由官方来源采集任务按 source_url 幂等更新。
INSERT INTO official_policy_briefs (
    title, summary, category, audience_tags, source_name, source_url,
    source_host, published_on, status
) VALUES
(
    '广东税务发布支持现代化产业体系建设措施（2.0版）',
    '措施继续强调研发费用加计扣除、高新技术企业所得税优惠、先进制造业增值税加计抵减等支持方向。企业是否适用须结合行业、纳税人和资质条件逐项核验。',
    'TAX',
    '["FINANCE","GM"]'::jsonb,
    '国家税务总局广东省税务局',
    'https://guangdong.chinatax.gov.cn/gdsw/ssfggds/2026-04/02/content_038c66df7fe14bdb8988dc370eb6b0f1.shtml',
    'guangdong.chinatax.gov.cn',
    DATE '2026-04-02',
    'ACTIVE'
),
(
    '财政部、税务总局明确2026年出口业务增值税和消费税政策',
    '公告自2026年1月1日起施行，明确生产企业出口自产及视同自产货物等业务的退（免）税衔接口径。公司存在出口业务时，应按商品代码、收汇和申报条件核对适用方式。',
    'EXPORT',
    '["FINANCE","GM","SALES"]'::jsonb,
    '财政部、税务总局',
    'https://www.mof.gov.cn/jrttts/202602/t20260203_3983176.htm',
    'www.mof.gov.cn',
    DATE '2026-01-30',
    'ACTIVE'
),
(
    '小榄镇推进重点产品质量治理提升行动',
    '小榄镇提出强化源头质量管控、增加重点产品抽检覆盖，并关注CCC认证、虚假认证和假冒伪劣等问题。电器制造企业可据此复核认证、原料、过程和出厂检验台账。',
    'QUALITY',
    '["GM","PRODUCTION","QA"]'::jsonb,
    '中山市小榄镇人民政府',
    'https://www.zs.gov.cn/zsxlz/gkmlpt/content/2/2619/post_2619510.html',
    'www.zs.gov.cn',
    DATE '2026-06-05',
    'ACTIVE'
),
(
    '中山市市场监督管理局公布2026年度“双随机、一公开”抽查工作计划',
    '年度抽查计划已经发布。总经办和质量部门可打开官方原文核对涉及本企业的抽查事项、检查对象和时间安排，并提前整理对应合规材料。',
    'INSPECTION',
    '["GM","QA","HR"]'::jsonb,
    '中山市市场监督管理局',
    'https://www.zs.gov.cn/zjj/zdlyxx/jdcctb/content/post_2600430.html',
    'www.zs.gov.cn',
    DATE '2026-03-24',
    'ACTIVE'
),
(
    '小榄镇部署安全生产和消防安全重点工作',
    '会议提出持续加强危化品、工贸、特种设备和消防等重点领域治理，并推进分租式厂房等隐患排查。总经办可据此检查企业风险分级、消防和应急预案台账。',
    'SAFETY',
    '["GM","HR","SECURITY","PRODUCTION"]'::jsonb,
    '中山市小榄镇人民政府',
    'https://www.zs.gov.cn/xlz/zwdt/content/post_2604950.html',
    'www.zs.gov.cn',
    DATE '2026-04-10',
    'ACTIVE'
)
ON CONFLICT (source_url) DO NOTHING;
