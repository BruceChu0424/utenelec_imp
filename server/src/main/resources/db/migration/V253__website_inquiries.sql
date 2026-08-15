-- =====================================================================
-- V253：官网询盘汇入（官网留言统一进 IMP 综合营销工作台）
-- =====================================================================
-- 背景：官网（website/，Next.js）已自带询盘收件箱；公司要求客户留言统一到
--   IMP 一个工作台处理。官网询盘落库后由服务端推送到
--   POST /api/website-inquiries/ingest（共享密钥 + source_id 幂等），
--   销售在 IMP 内跟进、关闭或一键转客户主档；官网后台保留只读副本。
-- 表结构：website_inquiries（来源快照 + 状态机 + 可选关联客户）。
-- 审计列：实体继承 BaseEntity（四审计列），建表一次带全（V94 教训）。
-- 审计触发器：本迁移直接为表建 trg_audit_*（V252 全量 sweep 只覆盖当时已有表）。
-- 权限：webinquiry:view 查看 / webinquiry:manage 跟进·关闭·转客户；
--   均不回填任何部门（最小授权），由权限管理页授综合营销部。
-- =====================================================================

CREATE TABLE IF NOT EXISTS website_inquiries (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id            TEXT        NOT NULL UNIQUE,  -- 官网 inquiries.id（重推幂等）
    name                 TEXT        NOT NULL,
    phone                TEXT,
    email                TEXT,
    company              TEXT,
    market               TEXT,                          -- 目标市场/国家
    customer_type        TEXT,                          -- distributor/project/oem/designer/other
    required_standard    TEXT,                          -- 目标市场要求的标准
    product_interest     TEXT,                          -- 意向产品
    request_type         TEXT,                          -- quotation/sample/technical/partnership/other
    estimated_quantity   TEXT,
    target_schedule      TEXT,
    preferred_contact    TEXT,
    message              TEXT        NOT NULL,
    source               TEXT        NOT NULL DEFAULT 'contact', -- contact/join/partner/product/studio
    locale               TEXT        NOT NULL DEFAULT 'zh',
    status               TEXT        NOT NULL DEFAULT 'new',     -- new/following/converted/closed
    assignee_employee_id UUID        REFERENCES employees(id),   -- 跟进人
    client_id            UUID        REFERENCES clients(id),     -- 转客户后关联
    note                 TEXT,                                  -- 跟进备注（最近一次）
    received_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           UUID,
    updated_by           UUID
);

CREATE INDEX IF NOT EXISTS idx_website_inquiries_received ON website_inquiries(received_at DESC);
CREATE INDEX IF NOT EXISTS idx_website_inquiries_status   ON website_inquiries(status);
CREATE INDEX IF NOT EXISTS idx_website_inquiries_assignee ON website_inquiries(assignee_employee_id)
    WHERE assignee_employee_id IS NOT NULL;

-- 行级审计（与 V252 sweep 同一触发器函数；本表晚于 V252，需自行登记）
DROP TRIGGER IF EXISTS trg_audit_website_inquiries ON website_inquiries;
CREATE TRIGGER trg_audit_website_inquiries
    AFTER INSERT OR UPDATE OR DELETE ON website_inquiries
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

INSERT INTO permissions (code, name, module, category, sort_order) VALUES
    ('webinquiry:view',   '官网询盘-查看',       '销售管理', '官网询盘', 90),
    ('webinquiry:manage', '官网询盘-跟进与转客户', '销售管理', '官网询盘', 91)
ON CONFLICT (code) DO NOTHING;
