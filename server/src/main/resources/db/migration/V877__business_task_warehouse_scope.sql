-- Personal business tasks use physical responsibility, without implicit super-admin scope.
-- The one-argument function retains existing document browsing/command behavior.
CREATE OR REPLACE FUNCTION fn_user_warehouse_access(p_user uuid, p_business_tasks boolean)
RETURNS TABLE(role text, keeper_warehouse_ids uuid[], scope_warehouse_ids uuid[],
              includes_unassigned boolean, warehouse_member boolean)
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE warehouse_departments(id) AS (
        SELECT id FROM departments WHERE code = 'SUB_WH' AND NOT is_deleted
        UNION ALL
        SELECT child.id FROM departments child
        JOIN warehouse_departments parent ON child.parent_id = parent.id
        WHERE NOT child.is_deleted
    ), me AS (
        SELECT account.id AS user_id, employee.id AS employee_id
        FROM users account
        JOIN employees employee ON employee.id = account.employee_id
        WHERE account.id = p_user AND NOT account.is_deleted AND account.status = 'active'
          AND NOT employee.is_deleted AND employee.status <> 'resigned'
    ), registered AS (
        SELECT keeper.warehouse_id
        FROM warehouse_keepers keeper
        JOIN me ON me.employee_id = keeper.employee_id
        JOIN warehouses warehouse ON warehouse.id = keeper.warehouse_id AND NOT warehouse.is_deleted
    ), facts AS (
        SELECT EXISTS (SELECT 1 FROM me WHERE me.user_id = ANY(CASE WHEN p_business_tasks THEN fn_warehouse_designated_supervisor_user_ids() ELSE fn_warehouse_supervisor_user_ids() END)) AS supervisor,
               EXISTS (SELECT 1 FROM registered
                       WHERE registered.warehouse_id IS DISTINCT FROM fn_warehouse_root_id()) AS keeper,
               ARRAY(SELECT warehouse_id FROM registered ORDER BY warehouse_id) AS keeper_ids,
               EXISTS (SELECT 1 FROM me JOIN employees employee ON employee.id = me.employee_id
                       WHERE employee.department_id IN (SELECT id FROM warehouse_departments)
                          OR EXISTS (SELECT 1 FROM employee_secondary_departments secondary
                                     WHERE secondary.employee_id = employee.id
                                       AND secondary.department_id IN (SELECT id FROM warehouse_departments)))
                   AS member
    ), uncovered AS (
        SELECT ARRAY(SELECT warehouse.id FROM warehouses warehouse
                     WHERE cardinality(fn_warehouse_keeper_user_ids(ARRAY[warehouse.id])) = 0
                     ORDER BY warehouse.id) AS ids,
               EXISTS (SELECT 1 FROM warehouses warehouse
                       WHERE NOT warehouse.is_deleted
                         AND cardinality(fn_warehouse_keeper_user_ids(ARRAY[warehouse.id])) > 0) AS configured
    )
    SELECT CASE WHEN facts.supervisor THEN 'SUPERVISOR' WHEN facts.keeper THEN 'KEEPER' ELSE 'OTHER' END,
           facts.keeper_ids,
           CASE WHEN facts.supervisor THEN NULL
                WHEN facts.keeper THEN fn_warehouse_scope_ids(ARRAY(
                    SELECT warehouse_id FROM registered
                    WHERE warehouse_id IS DISTINCT FROM fn_warehouse_root_id()))
                WHEN NOT uncovered.configured THEN NULL
                ELSE uncovered.ids END,
           NOT facts.supervisor AND NOT facts.keeper,
           facts.member
    FROM facts CROSS JOIN uncovered;
$$;
CREATE OR REPLACE FUNCTION fn_user_warehouse_access(p_user uuid)
RETURNS TABLE(role text, keeper_warehouse_ids uuid[], scope_warehouse_ids uuid[],
              includes_unassigned boolean, warehouse_member boolean)
LANGUAGE sql STABLE AS $$
    SELECT * FROM fn_user_warehouse_access(p_user, FALSE);
$$;

COMMENT ON FUNCTION fn_user_warehouse_access(uuid, boolean) IS
    'Business task responsibility excludes implicit super-admin supervision; explicit warehouse keepers and designated supervisors retain their existing scope and unassigned-work fallback.';