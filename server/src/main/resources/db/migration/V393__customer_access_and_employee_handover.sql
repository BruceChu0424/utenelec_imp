-- V393: strict customer ownership, per-customer read sharing, and audited
-- employee data handover.
--
-- Current responsibility is mutable. Historical actors (maker/approver/
-- created_by/audit actor) are not rewritten by this migration or by the
-- runtime handover service.

-- Sales staff must be owner-scoped by default. Company-wide visibility stays
-- available only through an explicit personal/department exception or the
-- super-administrator bypass.
DELETE FROM department_permissions assignment
USING departments department, permissions permission
WHERE assignment.department_id = department.id
  AND assignment.permission_id = permission.id
  AND department.code IN ('DEPT_SALES', 'DEPT_RAIL')
  AND permission.code IN ('client:view:all', 'sales:view:all');

-- Keep responsibility changes separate from ordinary data edits. Existing
-- department-level client editors/offboarding operators receive the matching
-- split action so the forward migration does not strand current operators.
INSERT INTO permissions
    (code, name, module, category, sort_order, action_type, description,
     active, assignable)
VALUES
    ('client:assign', '设置客户负责人和可见人', '基础资料', '客户资料', 46,
     'ASSIGN', '变更客户当前负责人并维护单客户只读可见人员', TRUE, TRUE),
    ('employee:handover', '办理人员数据交接', '人事行政', '员工档案', 70,
     'ASSIGN', '预览并转移员工当前责任，保留历史操作人与审计事实', TRUE, TRUE)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    module = EXCLUDED.module,
    category = EXCLUDED.category,
    sort_order = EXCLUDED.sort_order,
    action_type = EXCLUDED.action_type,
    description = EXCLUDED.description,
    active = TRUE,
    assignable = TRUE;

INSERT INTO department_permissions (department_id, permission_id)
SELECT existing.department_id, added.id
FROM department_permissions existing
JOIN permissions source
  ON source.id = existing.permission_id
JOIN permissions added
  ON added.code = CASE source.code
      WHEN 'client:edit' THEN 'client:assign'
      WHEN 'employee:offboard' THEN 'employee:handover'
  END
WHERE source.code IN ('client:edit', 'employee:offboard')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role_id, permission_id)
SELECT existing.role_id, added.id
FROM role_permissions existing
JOIN permissions source
  ON source.id = existing.permission_id
JOIN permissions added
  ON added.code = CASE source.code
      WHEN 'client:edit' THEN 'client:assign'
      WHEN 'employee:offboard' THEN 'employee:handover'
  END
WHERE source.code IN ('client:edit', 'employee:offboard')
ON CONFLICT DO NOTHING;

INSERT INTO permission_surface_permissions (surface_id, permission_id)
SELECT surface.id, permission.id
FROM permission_surfaces surface
JOIN permissions permission
  ON permission.code = CASE surface.surface_key
      WHEN 'basic.client' THEN 'client:assign'
      WHEN 'org.employee' THEN 'employee:handover'
  END
WHERE surface.surface_key IN ('basic.client', 'org.employee')
ON CONFLICT (surface_id, permission_id) DO NOTHING;

-- Customer access changes have an aggregate monotonic CAS separate from the
-- ordinary customer edit @Version. Sharing-only changes still advance it.
ALTER TABLE clients
    ADD COLUMN access_version BIGINT NOT NULL DEFAULT 0;
ALTER TABLE clients
    ADD CONSTRAINT clients_access_version_chk
        CHECK (access_version >= 0) NOT VALID;
ALTER TABLE clients VALIDATE CONSTRAINT clients_access_version_chk;

CREATE TABLE client_visibility_grants (
    client_id              UUID NOT NULL,
    grantee_employee_id    UUID NOT NULL,
    active                 BOOLEAN NOT NULL DEFAULT TRUE,
    row_version            BIGINT NOT NULL DEFAULT 1,
    granted_by_user_id     UUID NOT NULL,
    revoked_by_user_id     UUID,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at             TIMESTAMPTZ,
    PRIMARY KEY (client_id, grantee_employee_id),
    CONSTRAINT client_visibility_grants_client_fk
        FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE RESTRICT,
    CONSTRAINT client_visibility_grants_employee_fk
        FOREIGN KEY (grantee_employee_id) REFERENCES employees(id) ON DELETE RESTRICT,
    CONSTRAINT client_visibility_grants_granted_by_fk
        FOREIGN KEY (granted_by_user_id) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT client_visibility_grants_revoked_by_fk
        FOREIGN KEY (revoked_by_user_id) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT client_visibility_grants_version_chk CHECK (row_version >= 1),
    CONSTRAINT client_visibility_grants_revoke_shape_chk CHECK (
        (active = TRUE AND revoked_at IS NULL AND revoked_by_user_id IS NULL)
        OR
        (active = FALSE AND revoked_at IS NOT NULL AND revoked_by_user_id IS NOT NULL)
    )
);

CREATE INDEX idx_client_visibility_grants_grantee_active
    ON client_visibility_grants(grantee_employee_id, client_id)
    WHERE active = TRUE;
CREATE INDEX idx_client_visibility_grants_client_active
    ON client_visibility_grants(client_id, grantee_employee_id)
    WHERE active = TRUE;

COMMENT ON TABLE client_visibility_grants IS
    'Per-customer read-only visibility. It never changes the customer owner or grants write authority.';
COMMENT ON COLUMN clients.access_version IS
    'Aggregate CAS for owner and per-customer visibility changes; independent from ordinary customer edit version';

-- A handover is atomic and append-only at the business level. The highest
-- sequence edge for one source+scope is the current successor; older rows are
-- retained as evidence and are never rewritten into historical documents.
CREATE TABLE employee_data_handovers (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sequence_no              BIGSERIAL NOT NULL UNIQUE,
    request_id               UUID NOT NULL UNIQUE,
    source_employee_id       UUID NOT NULL,
    target_employee_id       UUID NOT NULL,
    mode                     TEXT NOT NULL,
    effective_date           DATE NOT NULL,
    reason                   TEXT NOT NULL,
    status                   TEXT NOT NULL,
    result_summary           JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_by_user_id       UUID NOT NULL,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT employee_data_handovers_source_fk
        FOREIGN KEY (source_employee_id) REFERENCES employees(id) ON DELETE RESTRICT,
    CONSTRAINT employee_data_handovers_target_fk
        FOREIGN KEY (target_employee_id) REFERENCES employees(id) ON DELETE RESTRICT,
    CONSTRAINT employee_data_handovers_actor_fk
        FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT employee_data_handovers_distinct_chk
        CHECK (source_employee_id <> target_employee_id),
    CONSTRAINT employee_data_handovers_mode_chk
        CHECK (mode IN ('MANUAL', 'OFFBOARDING')),
    CONSTRAINT employee_data_handovers_status_chk
        CHECK (status IN ('EXECUTING', 'COMPLETED')),
    CONSTRAINT employee_data_handovers_reason_chk
        CHECK (btrim(reason) <> '' AND char_length(reason) <= 2000)
);

CREATE TABLE employee_data_handover_scopes (
    handover_id UUID NOT NULL,
    scope       TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (handover_id, scope),
    CONSTRAINT employee_data_handover_scopes_handover_fk
        FOREIGN KEY (handover_id) REFERENCES employee_data_handovers(id) ON DELETE RESTRICT,
    CONSTRAINT employee_data_handover_scopes_scope_chk CHECK (scope IN (
        'goods', 'client', 'sales', 'finance', 'purchase', 'subcontract',
        'production_plan', 'stock_doc'
    ))
);

CREATE INDEX idx_employee_data_handovers_source_latest
    ON employee_data_handovers(source_employee_id, sequence_no DESC)
    WHERE status = 'COMPLETED';
CREATE INDEX idx_employee_data_handovers_target_latest
    ON employee_data_handovers(target_employee_id, sequence_no DESC)
    WHERE status = 'COMPLETED';
CREATE INDEX idx_employee_data_handover_scopes_scope
    ON employee_data_handover_scopes(scope, handover_id);

COMMENT ON TABLE employee_data_handovers IS
    'Audited employee responsibility handover batch; immutable historical actors remain on source business records';
COMMENT ON TABLE employee_data_handover_scopes IS
    'Business owner scopes included in one handover batch; latest source+scope edge is authoritative';

-- New or newly changed responsibility references must point to a current
-- employee. Existing historical rows are not rewritten or rejected merely
-- because their original employee has since left.
CREATE OR REPLACE FUNCTION fn_require_current_employee_reference()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_column TEXT := TG_ARGV[0];
    v_new_id UUID := NULLIF(to_jsonb(NEW) ->> v_column, '')::UUID;
    v_old_id UUID;
    v_status TEXT;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        v_old_id := NULLIF(to_jsonb(OLD) ->> v_column, '')::UUID;
        IF v_new_id IS NOT DISTINCT FROM v_old_id THEN
            RETURN NEW;
        END IF;
    END IF;
    IF v_new_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT employee.status
    INTO v_status
    FROM employees employee
    WHERE employee.id = v_new_id
      AND employee.is_deleted = FALSE;
    IF v_status IS NULL OR v_status NOT IN ('active', 'probation', 'onLeave') THEN
        RAISE EXCEPTION 'responsibility target must be a current employee'
            USING ERRCODE = '23514',
                  CONSTRAINT = TG_TABLE_NAME || '_' || v_column || '_current_employee';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_clients_owner_current_employee
BEFORE INSERT OR UPDATE OF owner_employee_id ON clients
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('owner_employee_id');

CREATE TRIGGER trg_goods_owner_current_employee
BEFORE INSERT OR UPDATE OF owner_employee_id ON goods
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('owner_employee_id');

CREATE TRIGGER trg_suppliers_owner_current_employee
BEFORE INSERT OR UPDATE OF owner_employee_id ON suppliers
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('owner_employee_id');

CREATE TRIGGER trg_moulds_keeper_current_employee
BEFORE INSERT OR UPDATE OF keeper_id ON moulds
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('keeper_id');

CREATE TRIGGER trg_client_visibility_grantee_current_employee
BEFORE INSERT OR UPDATE OF grantee_employee_id ON client_visibility_grants
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('grantee_employee_id');

CREATE TRIGGER trg_employee_data_handover_target_current_employee
BEFORE INSERT OR UPDATE OF target_employee_id ON employee_data_handovers
FOR EACH ROW EXECUTE FUNCTION fn_require_current_employee_reference('target_employee_id');

CREATE TRIGGER trg_set_updated_at_client_visibility_grants
BEFORE UPDATE ON client_visibility_grants
FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_audit_client_visibility_grants
AFTER INSERT OR UPDATE OR DELETE ON client_visibility_grants
FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE TRIGGER trg_audit_employee_data_handovers
AFTER INSERT OR UPDATE OR DELETE ON employee_data_handovers
FOR EACH ROW EXECUTE FUNCTION fn_audit();

CREATE TRIGGER trg_audit_employee_data_handover_scopes
AFTER INSERT OR UPDATE OR DELETE ON employee_data_handover_scopes
FOR EACH ROW EXECUTE FUNCTION fn_audit();
