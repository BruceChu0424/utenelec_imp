-- V204 工程研发部 任务中心 + 生产 BOM 缺失转发（通用 rd_tasks 任务板）。
-- 单一持久表 rd_tasks：既是研发任务中心数据源，也承载待排产「等待研发部修改」状态。
-- 范式镜像 procurement_order_approval_cases（Pattern B：纯 JdbcTemplate + 记录，无 @Entity）。

CREATE TABLE IF NOT EXISTS rd_tasks (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_no               varchar(32) NOT NULL UNIQUE,
    title                 varchar(200) NOT NULL,
    description           text,
    category              varchar(20) NOT NULL CHECK (category IN ('BOM','DESIGN','SAMPLE','TRIAL','ECN','OTHER')),
    status                varchar(20) NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','IN_PROGRESS','DONE','CANCELED')),
    priority              varchar(10) NOT NULL DEFAULT 'NORMAL' CHECK (priority IN ('NORMAL','URGENT')),
    goods_id              uuid,         -- 关联货品/BOM（BOM 类任务必填）
    order_item_id         uuid,         -- 来源：待排产销售订单行（BOM 转发）
    source_doc_type       varchar(40),  -- 来源单据类型（如 SALES_ORDER_ITEM）
    source_doc_id         uuid,
    source_doc_no         varchar(64),
    assignee_employee_id  uuid,         -- 指派工程师（员工档案）
    reporter_employee_id  uuid NOT NULL,-- 制单人/转发人（员工档案）
    reporter_department_id uuid,
    due_date              date,
    started_at            timestamptz,
    completed_at          timestamptz,
    close_note            text,
    row_version           bigint NOT NULL DEFAULT 1 CHECK (row_version > 0),
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    created_by            uuid,
    updated_by            uuid,
    is_deleted            boolean NOT NULL DEFAULT false,
    CONSTRAINT rd_tasks_done_has_completed CHECK (
        (status <> 'DONE') OR (completed_at IS NOT NULL)
    )
);

COMMENT ON TABLE rd_tasks IS '工程研发部任务（BOM/设计/打样/试产/ECN）；生产 BOM 缺失转发自动建任务。';

CREATE INDEX IF NOT EXISTS idx_rd_tasks_status_category ON rd_tasks (status, category) WHERE is_deleted = false;
CREATE INDEX IF NOT EXISTS idx_rd_tasks_goods           ON rd_tasks (goods_id)       WHERE goods_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_rd_tasks_order_item      ON rd_tasks (order_item_id)  WHERE order_item_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_rd_tasks_assignee        ON rd_tasks (assignee_employee_id) WHERE assignee_employee_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_rd_tasks_reporter        ON rd_tasks (reporter_employee_id);
-- BOM 转发幂等：同一 order_item + goods 同时只允许一个未完成 BOM 任务（防并发转发重复建单+重复通知）。
CREATE UNIQUE INDEX IF NOT EXISTS uq_rd_tasks_open_bom  ON rd_tasks (order_item_id, goods_id)
    WHERE category = 'BOM' AND status IN ('OPEN','IN_PROGRESS') AND is_deleted = false;

-- 通用审计触发器（fn_audit 见 V05；写入 audit_log，actor 读 current_setting('app.actor_id')）。
DROP TRIGGER IF EXISTS trg_audit_rd_tasks ON rd_tasks;
CREATE TRIGGER trg_audit_rd_tasks
    AFTER INSERT OR UPDATE OR DELETE ON rd_tasks
    FOR EACH ROW EXECUTE FUNCTION fn_audit();

-- 权限点登记（镜像 V78/V196 种子范式）。
INSERT INTO permissions (code, name, category, sort_order) VALUES
    ('rd_task:view',    '查看研发任务',          '工程研发', 10),
    ('rd_task:edit',    '维护研发任务',          '工程研发', 11),
    ('rd_task:resolve', '完成研发任务',          '工程研发', 12),
    ('production_plan:forward_rd', '转发BOM缺失给工程研发', '生产管理', 402)
ON CONFLICT (code) DO NOTHING;

-- rd_task:* 默认授工程研发部（DEPT_ENG）；部门配置向上取并集，子部门（GRP_PE/GRP_RD）成员自动继承。
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d, permissions p
WHERE p.code IN ('rd_task:view', 'rd_task:edit', 'rd_task:resolve')
  AND d.is_deleted = false
  AND d.code = 'DEPT_ENG'
ON CONFLICT DO NOTHING;

-- production_plan:forward_rd 授生产部 / 生产管理子部门（与 production_plan:view 同口径）。
INSERT INTO department_permissions (department_id, permission_id)
SELECT d.id, p.id
FROM departments d, permissions p
WHERE p.code = 'production_plan:forward_rd'
  AND d.is_deleted = false
  AND d.code IN ('DEPT_PROD', 'SUB_PLAN')
ON CONFLICT DO NOTHING;
