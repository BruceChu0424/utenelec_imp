-- 部门：邻接表(parent_id) + 语义(level) + 物化路径(path)
-- path 由触发器自动维护，业务/种子插入无需手填
CREATE TABLE departments (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code         TEXT NOT NULL UNIQUE,
    name         TEXT NOT NULL,
    parent_id    UUID REFERENCES departments(id) ON DELETE RESTRICT,
    level        TEXT NOT NULL CHECK (level IN ('公司','决策层','管理中心','一级部门','二级班组','三级科室')),
    manager_id   UUID,   -- FK 指向 employees，在 V03 employees 建表后补加约束
    sort_order   INT  NOT NULL DEFAULT 0,
    path         TEXT NOT NULL DEFAULT '/',
    headcount    INT  NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   UUID,
    updated_by   UUID,
    is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at   TIMESTAMPTZ
);
CREATE INDEX idx_departments_parent      ON departments(parent_id);
CREATE INDEX idx_departments_parent_sort ON departments(parent_id, sort_order);
CREATE INDEX idx_departments_path        ON departments(path text_ops);
COMMENT ON TABLE  departments IS '组织架构树（邻接表 parent_id + 语义 level + 物化路径 path）';
COMMENT ON COLUMN departments.manager_id IS '部门负责人（指向 employees.id）';
COMMENT ON COLUMN departments.headcount  IS '人数（冗余，定期/触发刷新）';

-- 自动维护 path = 父path || code || '/'（根节点 '/code/'）
CREATE OR REPLACE FUNCTION fn_dept_path() RETURNS TRIGGER AS $$
DECLARE
    v_parent_path TEXT;
BEGIN
    IF NEW.parent_id IS NULL THEN
        NEW.path := '/' || NEW.code || '/';
    ELSE
        SELECT path INTO v_parent_path FROM departments WHERE id = NEW.parent_id;
        NEW.path := COALESCE(v_parent_path, '/') || NEW.code || '/';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_dept_path
    BEFORE INSERT OR UPDATE OF parent_id, code ON departments
    FOR EACH ROW EXECUTE FUNCTION fn_dept_path();

-- 岗位：挂在部门下
CREATE TABLE positions (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code          TEXT NOT NULL,
    name          TEXT NOT NULL,
    department_id UUID REFERENCES departments(id) ON DELETE RESTRICT,
    level         TEXT,   -- 岗位职级（如 L1~L9 / 经理 / 主管 / 员）
    sort_order    INT  NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by    UUID,
    updated_by    UUID,
    is_deleted    BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at    TIMESTAMPTZ,
    CONSTRAINT uk_positions_code_dept UNIQUE (code, department_id)
);
COMMENT ON TABLE positions IS '岗位（挂在部门下）';
