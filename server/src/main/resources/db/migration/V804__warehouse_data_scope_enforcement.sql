-- =====================================================================
-- V804 (ADR-149) 仓库数据范围服务端强制: 主管 / 子仓负责人 / 其他人
-- =====================================================================
-- 用户口径(2026-10-04): 仓储部负责人或「仓库(14年版)」这个唯一主仓的负责人 = 主管, 看全部,
--   也能挑任一子仓看; 其余每个子仓在「仓库资料 > 设置负责人」登记一个负责人, 这个人只看、
--   只收自己子仓的任务, 徽章也只数自己的仓。没登记负责人的人看「没人负责的仓」和未定仓的任务,
--   任务不掉进无人区。
--
-- 此前(ADR-115 / V693 / V796)「我的仓库」只是前端可选的筛选参数: 不传 = 全部仓,
--   指定仓不校验是不是本人负责的仓; MINE = 我负责的仓 + 所有没负责人的仓, 覆盖全部在用仓时
--   直接退回全部; 徽章从不按仓分。V796 在测试服务器上已执行(其 Java 随 v2.4.0 一起回退),
--   本迁移按新口径重写它建的函数。
--
-- 本迁移不改表结构、不改任何数据, 只定义「一处判定」的数据库函数:
--   1. fn_warehouse_keeper_user_ids(ids)   REPLACE: 这些仓的子仓负责人(登记在本仓或主仓以下
--      各级上级仓; 登记在主仓上的是主管, 不算子仓负责人)。
--   2. fn_warehouse_designated_supervisor_user_ids() 新增: 指定的主管 = 仓储部(SUB_WH 子树)各部门
--      负责人 + 登记在主仓上的负责人(不含只因超管身份成为主管的账号);
--      fn_warehouse_supervisor_user_ids()  REPLACE: 主管 = 超管 + 指定的主管(列表范围用)。
--   3. fn_warehouse_responsible_user_ids() 新增: 登记过负责人(任一仓)或仓储部门负责人的账号 =
--      「仓库任务参与者」, 通知弹卡资格(ReviewNoticeAudience)把他们当作仓储部门成员;
--      fn_warehouse_notice_candidate_user_ids(仓) 新增: 这些仓的子仓负责人 + 指定的主管, 仓库类通知池
--      只按「这张单涉及的仓」纳入部门外的人, 不再把别的仓的负责人拉进来。
--   4. fn_user_warehouse_access(user)      新增: 角色 + 可见仓, 服务端 WarehouseDataScopeService
--      只调这一个函数(按请求缓存)。
--   5. fn_warehouse_notice_recipients(warehouses, pool) 新增: 仓库类通知收件人唯一规则
--      (该仓链上子仓负责人 ∩ 池; 没有 → 指定的主管 ∩ 池; 再没有 → 池)。
--   6. fn_procurement_item_inbound_warehouse_id / fn_inbound_expectation_warehouse_ids /
--      fn_procurement_order_inbound_warehouse_ids 新增: 预计到货的「所在仓」唯一定义
--      (订货表头子仓 → 采购/委外申请表头子仓 → 货品所属仓 → 表头写的主仓)。ADR-038 起订货不带仓,
--      inbound_expectations.warehouse_id 恒为空, 不再用它; 申请表头填的是主仓 001(测试服务器上全部如此)
--      时它只说明「进仓库」, 先按货品所属子仓落到具体的仓, 都没有才算主仓。
--   7. fn_stock_document_matches_warehouse_scope 改为四个参数(DROP V796 的三参数版): 库存单据的「所在仓」=
--      发出仓或调入仓, 两个都没有 = 未定仓; 第四个参数给出时, 这个人自己还没提交的草稿不论仓都算在范围内
--      (建单不限仓, 草稿不能因为选了范围外的仓就从制单人自己的列表、草稿箱和徽章里消失)。库存单据列表、
--      仓库草稿数、分段计数、生产退料待实收数同用这一个判定。
--   8. DROP fn_user_warehouse_scope_ids(V693「我的仓库」)、fn_notice_warehouse_visible(V796 读侧
--      通知过滤, 全库没有调用方; 通知改为发送时按负责人分发, 不再按读侧逐条重判)。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. 子仓负责人: 本仓 + 主仓以下各级上级仓登记的负责人(员工在职、账号启用)。
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_warehouse_keeper_user_ids(p_warehouse_ids uuid[])
RETURNS uuid[] LANGUAGE sql STABLE AS $$
    WITH RECURSIVE lineage(id) AS (
        SELECT id FROM warehouses
        WHERE id = ANY(COALESCE(p_warehouse_ids, ARRAY[]::uuid[])) AND NOT is_deleted
        UNION
        SELECT parent.id FROM lineage child
        JOIN warehouses current ON current.id = child.id
        JOIN warehouses parent ON parent.id = current.parent_id AND NOT parent.is_deleted
    )
    SELECT COALESCE(array_agg(DISTINCT account.id ORDER BY account.id), ARRAY[]::uuid[])
    FROM warehouse_keepers keeper
    JOIN lineage ON lineage.id = keeper.warehouse_id
    JOIN employees employee ON employee.id = keeper.employee_id
     AND NOT employee.is_deleted AND employee.status <> 'resigned'
    JOIN users account ON account.employee_id = employee.id
     AND NOT account.is_deleted AND account.status = 'active'
    WHERE keeper.warehouse_id IS DISTINCT FROM fn_warehouse_root_id();
$$;

COMMENT ON FUNCTION fn_warehouse_keeper_user_ids(uuid[]) IS
    'V804 (ADR-149) 子仓负责人账号: 登记在本仓或主仓以下各级上级仓、员工在职且账号启用; 登记在主仓上的是主管, 不在此列';

-- ---------------------------------------------------------------------
-- 2. 主管。指定的主管 = 仓储部(SUB_WH 子树)部门负责人 + 登记在主仓上的负责人;
--    主管 = 超管 + 指定的主管(列表范围用)。通知分发的「主管」一级只认指定的主管: 超管几乎总在
--    权限池里, 把他算进去会让「再没有才发整个池」那一级永远到不了, 通知全落到超管一个人身上。
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_warehouse_designated_supervisor_user_ids()
RETURNS uuid[] LANGUAGE sql STABLE AS $$
    WITH RECURSIVE warehouse_departments(id) AS (
        SELECT id FROM departments WHERE code = 'SUB_WH' AND NOT is_deleted
        UNION ALL
        SELECT child.id FROM departments child
        JOIN warehouse_departments parent ON child.parent_id = parent.id
        WHERE NOT child.is_deleted
    )
    SELECT COALESCE(array_agg(DISTINCT account.id ORDER BY account.id), ARRAY[]::uuid[])
    FROM users account
    JOIN employees employee ON employee.id = account.employee_id
    WHERE NOT account.is_deleted AND account.status = 'active'
      AND NOT employee.is_deleted AND employee.status <> 'resigned'
      AND (EXISTS (SELECT 1 FROM departments department
                   JOIN warehouse_departments scope ON scope.id = department.id
                   WHERE department.manager_id = employee.id)
           OR EXISTS (SELECT 1 FROM warehouse_keepers keeper
                      WHERE keeper.employee_id = employee.id
                        AND keeper.warehouse_id = fn_warehouse_root_id()));
$$;

COMMENT ON FUNCTION fn_warehouse_designated_supervisor_user_ids() IS
    'V804 (ADR-149) 指定的仓库主管账号: 仓储部(SUB_WH 子树)部门负责人、登记在主仓上的负责人(不含只因超管身份成为主管的账号); 通知分发的主管一级只认它';

CREATE OR REPLACE FUNCTION fn_warehouse_supervisor_user_ids()
RETURNS uuid[] LANGUAGE sql STABLE AS $$
    SELECT COALESCE(array_agg(DISTINCT id ORDER BY id), ARRAY[]::uuid[])
    FROM (
        SELECT unnest(fn_warehouse_designated_supervisor_user_ids()) AS id
        UNION
        SELECT account.id
        FROM users account
        JOIN employees employee ON employee.id = account.employee_id
        WHERE account.is_super_admin AND NOT account.is_deleted AND account.status = 'active'
          AND NOT employee.is_deleted AND employee.status <> 'resigned'
    ) supervisors;
$$;

COMMENT ON FUNCTION fn_warehouse_supervisor_user_ids() IS
    'V804 (ADR-149) 仓库主管账号(列表范围): 超管 + 指定的主管(仓储部门负责人、登记在主仓上的负责人); 员工在职且账号启用';

-- ---------------------------------------------------------------------
-- 3. 负责人池扩展: 任一在用仓登记的有效负责人 + 仓储部门负责人(不含只因超管身份成为主管的账号)。
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_warehouse_responsible_user_ids()
RETURNS uuid[] LANGUAGE sql STABLE AS $$
    WITH RECURSIVE warehouse_departments(id) AS (
        SELECT id FROM departments WHERE code = 'SUB_WH' AND NOT is_deleted
        UNION ALL
        SELECT child.id FROM departments child
        JOIN warehouse_departments parent ON child.parent_id = parent.id
        WHERE NOT child.is_deleted
    )
    SELECT COALESCE(array_agg(DISTINCT account.id ORDER BY account.id), ARRAY[]::uuid[])
    FROM users account
    JOIN employees employee ON employee.id = account.employee_id
    WHERE NOT account.is_deleted AND account.status = 'active'
      AND NOT employee.is_deleted AND employee.status <> 'resigned'
      AND (EXISTS (SELECT 1 FROM warehouse_keepers keeper
                   JOIN warehouses warehouse ON warehouse.id = keeper.warehouse_id AND NOT warehouse.is_deleted
                   WHERE keeper.employee_id = employee.id)
           OR EXISTS (SELECT 1 FROM departments department
                      JOIN warehouse_departments scope ON scope.id = department.id
                      WHERE department.manager_id = employee.id));
$$;

COMMENT ON FUNCTION fn_warehouse_responsible_user_ids() IS
    'V804 (ADR-149) 仓库任务参与者(登记过仓库负责人或担任仓储部门负责人的账号): 通知弹卡资格把他们当作仓储部门成员';

-- 一张仓库类单据的通知池要纳入的部门外的人: 这些仓(含上级链)的子仓负责人 + 指定的主管。
CREATE OR REPLACE FUNCTION fn_warehouse_notice_candidate_user_ids(p_warehouse_ids uuid[])
RETURNS uuid[] LANGUAGE sql STABLE AS $$
    SELECT COALESCE(array_agg(DISTINCT id ORDER BY id), ARRAY[]::uuid[])
    FROM (
        SELECT unnest(fn_warehouse_keeper_user_ids(array_remove(COALESCE(p_warehouse_ids, ARRAY[]::uuid[]), NULL))) AS id
        UNION
        SELECT unnest(fn_warehouse_designated_supervisor_user_ids())
    ) candidates;
$$;

COMMENT ON FUNCTION fn_warehouse_notice_candidate_user_ids(uuid[]) IS
    'V804 (ADR-149) 仓库类通知池要纳入的部门外账号: 涉及仓(含上级链)的子仓负责人 + 指定的主管; 不含别的仓的负责人';

-- ---------------------------------------------------------------------
-- 4. 账号的仓库数据范围(唯一判定)。
--    role: SUPERVISOR 主管 / KEEPER 子仓负责人 / OTHER 其他人
--    keeper_warehouse_ids: 本人登记负责的在用仓(含主仓)
--    scope_warehouse_ids: 默认可见仓; NULL = 不限(主管; 或全公司还没有任何有效子仓负责人)
--      KEEPER = 本人负责的子仓及其下级; OTHER = 没有有效子仓负责人的仓(含已删除的历史仓)
--    includes_unassigned: 默认范围是否包含未定仓的任务(OTHER 包含, KEEPER 不含)
--    warehouse_member: 主部门或兼职部门在仓储部(SUB_WH)子树内
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_user_warehouse_access(p_user uuid)
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
        SELECT EXISTS (SELECT 1 FROM me WHERE me.user_id = ANY(fn_warehouse_supervisor_user_ids())) AS supervisor,
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

COMMENT ON FUNCTION fn_user_warehouse_access(uuid) IS
    'V804 (ADR-149) 仓库数据范围唯一判定: 角色(SUPERVISOR/KEEPER/OTHER)、本人登记的仓、默认可见仓(NULL=不限)、是否含未定仓任务、是否仓储部门成员';

-- ---------------------------------------------------------------------
-- 5. 仓库类通知收件人唯一规则。
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_warehouse_notice_recipients(p_warehouse_ids uuid[], p_pool uuid[])
RETURNS uuid[] LANGUAGE sql STABLE AS $$
    WITH pool AS (
        SELECT DISTINCT unnest(COALESCE(p_pool, ARRAY[]::uuid[])) AS id
    ), keepers AS (
        SELECT pool.id FROM pool
        WHERE pool.id = ANY(fn_warehouse_keeper_user_ids(array_remove(COALESCE(p_warehouse_ids, ARRAY[]::uuid[]), NULL)))
    ), supervisors AS (
        SELECT pool.id FROM pool WHERE pool.id = ANY(fn_warehouse_designated_supervisor_user_ids())
    )
    SELECT COALESCE(
        CASE WHEN EXISTS (SELECT 1 FROM keepers) THEN ARRAY(SELECT id FROM keepers ORDER BY id)
             WHEN EXISTS (SELECT 1 FROM supervisors) THEN ARRAY(SELECT id FROM supervisors ORDER BY id)
             ELSE ARRAY(SELECT id FROM pool ORDER BY id) END,
        ARRAY[]::uuid[]);
$$;

COMMENT ON FUNCTION fn_warehouse_notice_recipients(uuid[], uuid[]) IS
    'V804 (ADR-149) 仓库类通知收件人: 该仓链上子仓负责人 ∩ 池; 没有则指定的主管(仓储部门负责人、主仓负责人, 不含只是超管的账号) ∩ 池; 再没有(还没配置)才发整个池';

-- ---------------------------------------------------------------------
-- 6. 预计到货的「所在仓」: 订货表头子仓 → 采购/委外申请表头子仓 → 货品所属仓 → 表头写的主仓。
--    表头写主仓(001)只说明「进仓库」, 不当成具体的仓; 子仓负责人按货品所属子仓收到这张单。
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_procurement_item_inbound_warehouse_id(p_order_type text, p_order_item uuid, p_goods uuid)
RETURNS uuid LANGUAGE sql STABLE AS $$
    WITH heads AS (
        SELECT CASE p_order_type
            WHEN 'PURCHASE' THEN (
                SELECT header.warehouse_id FROM purchase_order_items item
                JOIN purchase_orders header ON header.id = item.order_id
                WHERE item.id = p_order_item)
            WHEN 'SUBCONTRACT' THEN (
                SELECT header.warehouse_id FROM subcontract_order_items item
                JOIN subcontract_orders header ON header.id = item.order_id
                WHERE item.id = p_order_item)
        END AS order_warehouse_id,
        CASE p_order_type
            WHEN 'PURCHASE' THEN (
                SELECT request.warehouse_id FROM (
                    SELECT source.request_item_id, source.line_no FROM purchase_order_item_sources source
                    WHERE source.order_item_id = p_order_item
                    UNION ALL
                    SELECT item.request_item_id, 0 FROM purchase_order_items item
                    WHERE item.id = p_order_item AND item.request_item_id IS NOT NULL
                ) link
                JOIN purchase_request_items request_item ON request_item.id = link.request_item_id
                JOIN purchase_requests request ON request.id = request_item.request_id
                WHERE request.warehouse_id IS NOT NULL
                ORDER BY link.line_no, request.id LIMIT 1)
            WHEN 'SUBCONTRACT' THEN (
                SELECT application.warehouse_id FROM (
                    SELECT source.application_item_id, source.line_no FROM subcontract_order_item_sources source
                    WHERE source.order_item_id = p_order_item
                    UNION ALL
                    SELECT item.application_item_id, 0 FROM subcontract_order_items item
                    WHERE item.id = p_order_item AND item.application_item_id IS NOT NULL
                ) link
                JOIN subcontract_application_items application_item ON application_item.id = link.application_item_id
                JOIN subcontract_applications application ON application.id = application_item.application_id
                WHERE application.warehouse_id IS NOT NULL
                ORDER BY link.line_no, application.id LIMIT 1)
        END AS request_warehouse_id,
        fn_warehouse_root_id() AS root_id
    )
    SELECT COALESCE(
        NULLIF(heads.order_warehouse_id, heads.root_id),
        NULLIF(heads.request_warehouse_id, heads.root_id),
        (SELECT goods.owning_warehouse_id FROM goods WHERE goods.id = p_goods),
        heads.order_warehouse_id,
        heads.request_warehouse_id)
    FROM heads;
$$;

COMMENT ON FUNCTION fn_procurement_item_inbound_warehouse_id(text, uuid, uuid) IS
    'V804 (ADR-149) 采购/委外订货行的到货仓: 订货表头子仓, 没有则申请表头子仓, 再没有则货品所属仓, 最后才是表头写的主仓; 都没有 = 未定仓';

CREATE OR REPLACE FUNCTION fn_inbound_expectation_warehouse_ids(p_expectation uuid)
RETURNS uuid[] LANGUAGE sql STABLE AS $$
    SELECT COALESCE(array_agg(DISTINCT resolved.warehouse_id ORDER BY resolved.warehouse_id)
                        FILTER (WHERE resolved.warehouse_id IS NOT NULL), ARRAY[]::uuid[])
    FROM (
        SELECT fn_procurement_item_inbound_warehouse_id(expectation.order_type, item.order_item_id, item.goods_id)
                   AS warehouse_id
        FROM inbound_expectations expectation
        JOIN inbound_expectation_items item ON item.expectation_id = expectation.id
        WHERE expectation.id = p_expectation
    ) resolved;
$$;

COMMENT ON FUNCTION fn_inbound_expectation_warehouse_ids(uuid) IS
    'V804 (ADR-149) 预计到货任务的所在仓(逐行到货仓去重); 空数组 = 未定仓。列表、计数、徽章、通知同用';

CREATE OR REPLACE FUNCTION fn_procurement_order_inbound_warehouse_ids(p_order_type text, p_order uuid)
RETURNS uuid[] LANGUAGE sql STABLE AS $$
    SELECT COALESCE(array_agg(DISTINCT resolved.warehouse_id ORDER BY resolved.warehouse_id)
                        FILTER (WHERE resolved.warehouse_id IS NOT NULL), ARRAY[]::uuid[])
    FROM (
        SELECT fn_procurement_item_inbound_warehouse_id('PURCHASE', item.id, item.goods_id) AS warehouse_id
        FROM purchase_order_items item
        WHERE p_order_type = 'PURCHASE' AND item.order_id = p_order AND NOT item.is_deleted
        UNION ALL
        SELECT fn_procurement_item_inbound_warehouse_id('SUBCONTRACT', item.id, item.goods_id)
        FROM subcontract_order_items item
        WHERE p_order_type = 'SUBCONTRACT' AND item.order_id = p_order AND NOT item.is_deleted
    ) resolved;
$$;

COMMENT ON FUNCTION fn_procurement_order_inbound_warehouse_ids(text, uuid) IS
    'V804 (ADR-149) 采购/委外订货单的到货仓(逐行到货仓去重), 通知分发用; 与预计到货同一逐行规则';

-- ---------------------------------------------------------------------
-- 7. 库存单据的「所在仓」= 发出仓或调入仓; 两个都没有 = 未定仓; 制单人自己的草稿不论仓都算。
--    p_ids 为逗号分隔的仓库 id; p_unassigned = 范围是否包含未定仓; p_own_draft_maker = 制单人员工 id 文本
--    (只在本人默认范围传; 页面选了某个仓时传空串, 只看那个仓)。
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_stock_document_matches_warehouse_scope(uuid, text, boolean);

CREATE FUNCTION fn_stock_document_matches_warehouse_scope(
    p_document uuid, p_ids text, p_unassigned boolean, p_own_draft_maker text)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM stock_documents document
        WHERE document.id = p_document
          AND (ARRAY[document.warehouse_id, document.to_warehouse_id]
                   && COALESCE(string_to_array(NULLIF(p_ids, ''), ',')::uuid[], ARRAY[]::uuid[])
               OR (p_unassigned AND document.warehouse_id IS NULL AND document.to_warehouse_id IS NULL)
               OR (NULLIF(p_own_draft_maker, '') IS NOT NULL AND document.status = 0
                   AND document.maker_id = NULLIF(p_own_draft_maker, '')::uuid)));
$$;

COMMENT ON FUNCTION fn_stock_document_matches_warehouse_scope(uuid, text, boolean, text) IS
    'V804 (ADR-149) 库存单据在仓库范围内: 发出仓或调入仓在范围内; 两个都没有时按范围是否含未定仓; 给出制单人时他自己的草稿(未提交)不论仓都算。列表、仓库草稿数、分段计数、生产退料计数同用';

-- ---------------------------------------------------------------------
-- 8. 删除被取代的函数。
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_user_warehouse_scope_ids(uuid);
DROP FUNCTION IF EXISTS fn_notice_warehouse_visible(uuid, text, text, uuid, text, text);
