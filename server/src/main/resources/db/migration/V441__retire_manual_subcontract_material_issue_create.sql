-- V441: permanently retire blank/manual subcontract material-issue creation.
--
-- New subcontract outbound documents are generated only from the warehouse
-- subcontract-outbound task. Existing issue documents and their edit/delete/
-- approve/reverse authorities remain available for execution and audit.
-- Historical grants are retained as provenance; inactive catalog rows are
-- excluded by PermissionSurfaceCatalogRepository and cannot be delegated.

DO $$
DECLARE
    historical_grants_before BIGINT;
    historical_grants_after BIGINT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM permissions
        WHERE code = 'subcontract_material_issue:create'
    ) THEN
        RAISE EXCEPTION
            'V441 cannot retire missing subcontract material-issue create permission';
    END IF;

    SELECT count(*)
    INTO historical_grants_before
    FROM (
        SELECT permission_id FROM department_permissions
        UNION ALL SELECT permission_id FROM role_permissions
        UNION ALL SELECT permission_id FROM user_permission_overrides
        UNION ALL SELECT permission_id FROM manager_permission_delegations
    ) source
    JOIN permissions permission ON permission.id = source.permission_id
    WHERE permission.code = 'subcontract_material_issue:create';

    UPDATE permissions
    SET active = FALSE,
        assignable = FALSE,
        name = '历史委外发料手工新建入口（已停用）',
        description =
            '新委外出仓只能从仓库委外出仓任务生成；保留本权限行和既有授权仅用于审计追溯'
    WHERE code = 'subcontract_material_issue:create';

    SELECT count(*)
    INTO historical_grants_after
    FROM (
        SELECT permission_id FROM department_permissions
        UNION ALL SELECT permission_id FROM role_permissions
        UNION ALL SELECT permission_id FROM user_permission_overrides
        UNION ALL SELECT permission_id FROM manager_permission_delegations
    ) source
    JOIN permissions permission ON permission.id = source.permission_id
    WHERE permission.code = 'subcontract_material_issue:create';

    IF historical_grants_after <> historical_grants_before THEN
        RAISE EXCEPTION 'V441 changed historical material-issue create grants';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM permissions
        WHERE code = 'subcontract_material_issue:create'
          AND active = FALSE
          AND assignable = FALSE
    ) THEN
        RAISE EXCEPTION 'V441 failed to retire material-issue create permission';
    END IF;

    IF (
        SELECT count(*) FROM permissions
        WHERE code IN (
            'subcontract_material_issue:view',
            'subcontract_material_issue:edit',
            'subcontract_material_issue:delete',
            'subcontract_material_issue:approve',
            'subcontract_material_issue:reverse')
          AND active = TRUE
          AND assignable = TRUE
    ) <> 5 THEN
        RAISE EXCEPTION
            'V441 requires existing material-issue history/execution permissions';
    END IF;
END;
$$;

-- Force access-token authorization snapshots to refresh after the retirement.
UPDATE authorization_state
SET epoch = epoch + 1,
    updated_at = CURRENT_TIMESTAMP
WHERE singleton_id = 1;
