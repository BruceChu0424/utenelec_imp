-- =====================================================================
-- V459：部门定向审核待办弹窗——兼职部门模型、通知聚合定位/办结撤回/稍后提醒
-- =====================================================================
-- 背景（方案：docs/01-规划/部门定向审核待办弹窗-方案与执行计划.md）：
--   弹卡资格 = (主部门 ∈ 部门子树 OR 兼职部门 ∈ 部门子树) AND 持有该业务块
--   职责权限码——「只有部门」或「只有权限」都不推。此前 employees 只有单值
--   department_id，全库无兼职表达；本迁移新增 employee_secondary_departments，
--   权限合成把兼职部门配置（含其祖先递归）并入现有并集（应用层实现）。
--   notices 增加聚合定位（aggregate_kind/aggregate_id）与办结撤回
--   （resolved_at/resolved_reason）：审核完成后按聚合批量 resolve，弹卡流
--   停止展示、通知中心灰显「已办结」；历史行全 NULL = 永不撤回，走既有
--   已读流程（旧数据零行为变化）。notice_user_states.snoozed_until 承载
--   「稍后再看」跨设备一致的稍后重弹语义。
--   review_inbox:view 登记「我的待审收件台」（弹卡入口的聚合页）与其权限面。
-- 零默认 grant（新码按部门矩阵/个人覆盖显式授予）；PRESERVE 新表 1 张。
-- 幂等：DDL 由 Flyway 单调执行；DML 均 ON CONFLICT DO NOTHING/UPDATE。
-- 同步：docs/数据迁移/README.md 头部计数（420→421）、
--       server/ops/reset_business_data.sql 白名单（V458/420→V459/421，
--       PRESERVE 95→96）、迁移说明 79。
-- =====================================================================

-- ====================== 1) 兼职部门（组织归属的第二层） ======================

CREATE TABLE employee_secondary_departments (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id   UUID NOT NULL
        REFERENCES employees(id) ON DELETE RESTRICT,
    department_id UUID NOT NULL
        REFERENCES departments(id) ON DELETE RESTRICT,
    started_on    DATE,
    note          VARCHAR(200),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    UUID REFERENCES users(id) ON DELETE RESTRICT,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by    UUID REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT employee_secondary_departments_note_chk CHECK (
        note IS NULL OR btrim(note) <> ''
    ),
    CONSTRAINT employee_secondary_departments_uk UNIQUE (employee_id, department_id)
);

COMMENT ON TABLE employee_secondary_departments IS
    'V459: 兼职部门归属——权限合成与待审弹卡定向的第二组织层；一行表示该员工在主部门之外兼任该部门（含其全部祖先递归的权限配置）';
COMMENT ON COLUMN employee_secondary_departments.started_on IS
    '兼职开始日期（仅展示/审计用，不参与权限时效判定）';

-- 兼职部门不得等于主部门：主部门归属由 employees.department_id 单值表达，
-- 等值兼职行是脏数据（应用层亦校验，此处为数据库兜底）。
CREATE OR REPLACE FUNCTION fn_validate_secondary_department_not_primary()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_primary UUID;
BEGIN
    SELECT department_id INTO v_primary
    FROM employees
    WHERE id = NEW.employee_id;
    IF v_primary = NEW.department_id THEN
        RAISE EXCEPTION 'secondary department must differ from the primary department'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'employee_secondary_departments_not_primary';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employee_secondary_departments_not_primary
    BEFORE INSERT OR UPDATE OF employee_id, department_id
    ON employee_secondary_departments
    FOR EACH ROW
    EXECUTE FUNCTION fn_validate_secondary_department_not_primary();

-- 兼职归属变化即时吊销旧 staff access token 的权限快照（V135 机制）：
-- 兼职是单人粒度授权，走 per-user auth_version 而非全局 epoch。
CREATE OR REPLACE FUNCTION fn_bump_employee_secondary_departments_auth_version()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_old_employee UUID;
    v_new_employee UUID;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_old_employee := OLD.employee_id;
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_new_employee := NEW.employee_id;
    END IF;
    IF v_old_employee IS NOT NULL THEN
        UPDATE users
        SET auth_version = auth_version + 1
        WHERE employee_id = v_old_employee;
    END IF;
    IF v_new_employee IS NOT NULL
       AND v_new_employee IS DISTINCT FROM v_old_employee THEN
        UPDATE users
        SET auth_version = auth_version + 1
        WHERE employee_id = v_new_employee;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_employee_secondary_departments_auth_version
    AFTER INSERT OR UPDATE OR DELETE ON employee_secondary_departments
    FOR EACH ROW
    EXECUTE FUNCTION fn_bump_employee_secondary_departments_auth_version();

CREATE TRIGGER trg_audit_employee_secondary_departments
    AFTER INSERT OR UPDATE OR DELETE ON employee_secondary_departments
    FOR EACH ROW
    EXECUTE FUNCTION fn_audit();

-- ====================== 2) notices 聚合定位与办结撤回 ======================

ALTER TABLE notices
    ADD COLUMN aggregate_kind VARCHAR(40),
    ADD COLUMN aggregate_id UUID,
    ADD COLUMN resolved_at TIMESTAMPTZ,
    ADD COLUMN resolved_reason VARCHAR(40),
    ADD CONSTRAINT notices_aggregate_shape_chk CHECK (
        (aggregate_kind IS NULL AND aggregate_id IS NULL)
        OR (aggregate_kind IS NOT NULL AND aggregate_id IS NOT NULL)
    ),
    ADD CONSTRAINT notices_aggregate_kind_chk CHECK (
        aggregate_kind IS NULL OR aggregate_kind = btrim(aggregate_kind)
    );

CREATE INDEX idx_notices_pending_aggregate
    ON notices (aggregate_kind, aggregate_id)
    WHERE resolved_at IS NULL;

COMMENT ON COLUMN notices.aggregate_kind IS
    'V459: 待办聚合类型（如 SALES_ORDER / PROCUREMENT_APPROVAL_CASE / IQC_BATCH）；非空时办结撤回按 (kind,id) 批量定位';
COMMENT ON COLUMN notices.aggregate_id IS
    'V459: 待办聚合主键（单据/审批 case/批次的 id）；历史行为 NULL=不参与撤回';
COMMENT ON COLUMN notices.resolved_at IS
    'V459: 业务办结时间（审核通过/驳回/取消等）；非空=该聚合全部接收人的弹卡停止展示、通知中心灰显「已办结」，历史行保持 NULL';
COMMENT ON COLUMN notices.resolved_reason IS
    'V459: 办结原因快照（APPROVED/REJECTED/CANCELED/COMPLETED/OUTBOUND_CREATED 等，自由短码）';

-- ====================== 3) 稍后再看（跨设备一致的服务端 snooze） ======================

ALTER TABLE notice_user_states
    ADD COLUMN snoozed_until TIMESTAMPTZ;

COMMENT ON COLUMN notice_user_states.snoozed_until IS
    'V459: 「稍后再看」到期时刻；未到期不出弹卡流（通知中心仍可见），到点未办结则下次到达重弹';

-- ====================== 4) 我的待审收件台权限码与权限面 ======================

INSERT INTO permissions
    (code, name, module, category, sort_order, action_type, description,
     active, assignable)
VALUES
    ('review_inbox:view',
     '查看我的待审收件台', '人事行政', '通知', 613,
     'VIEW', '跨业务域的个人待审收件台（审核弹卡的聚合入口页）；页面按各业务域「部门×职责权限码」资格过滤内容，本码只控页面可达',
     TRUE, TRUE)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    description = EXCLUDED.description,
    active = EXCLUDED.active,
    assignable = EXCLUDED.assignable;

INSERT INTO permission_surfaces (id, surface_key, name, sort_order, enabled) VALUES
    ('45900000-0000-4000-8000-000000000001',
     'reviews.inbox', '我的待审收件台', 276, TRUE)
ON CONFLICT (surface_key) DO NOTHING;

INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code = 'review_inbox:view'
WHERE surface.surface_key = 'reviews.inbox'
ON CONFLICT (surface_id, permission_id) DO NOTHING;
