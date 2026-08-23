package com.uten.imp.features.org.department;

import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Collection;
import java.util.Optional;
import java.util.UUID;

public interface DepartmentRepository extends JpaRepository<Department, UUID> {

    boolean existsByCode(String code);

    Optional<Department> findByCodeAndDeletedFalse(String code);

    List<Department> findByParentIdOrderBySortOrderAscNameAsc(UUID parentId);

    List<Department> findByManagerId(UUID managerId);

    List<Department> findByDeletedFalseOrderBySortOrderAscNameAsc();

    /**
     * Constant-cost capability check for page-permission delegation. Only
     * active organization nodes that may host employees confer manager scope.
     */
    @Query(value = """
            SELECT EXISTS(
                SELECT 1
                FROM departments department
                WHERE department.manager_id = :employeeId
                  AND department.is_deleted = false
                  AND department.level IN ('管理中心', '一级部门', '二级班组', '三级科室')
                  AND (
                      department.code <> 'GM'
                      OR (
                          department.code = 'GM'
                          AND EXISTS (
                              SELECT 1
                              FROM employees manager
                              JOIN departments company
                                ON company.id = department.parent_id
                              WHERE manager.id = :employeeId
                                AND manager.is_deleted = false
                                AND manager.status IN ('active', 'probation', 'onLeave')
                                AND manager.department_id = department.id
                                AND company.is_deleted = false
                                AND company.level = '公司'
                                AND company.parent_id IS NULL
                          )
                      )
                  )
            )
            """, nativeQuery = true)
    boolean existsManageableDepartmentByManagerId(
            @Param("employeeId") UUID employeeId);

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("SELECT department FROM Department department WHERE department.id = :id")
    Optional<Department> findByIdForUpdate(@Param("id") UUID id);

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("""
            SELECT department
            FROM Department department
            WHERE department.id IN :ids
            ORDER BY department.id
            """)
    List<Department> findAllByIdForUpdate(
            @Param("ids") Collection<UUID> ids);

    /**
     * Exact authority root used for a department-manager delegation snapshot.
     * A valid GM manager gets company authority; otherwise the nearest ancestor
     * whose manager_id is the employee is selected as the subtree root.
     */
    @Query(value = """
            WITH RECURSIVE ancestors AS (
                SELECT id, parent_id, code, level, manager_id, 0 AS depth
                FROM departments
                WHERE id = :departmentId
                  AND is_deleted = false
                UNION ALL
                SELECT parent.id,
                       parent.parent_id,
                       parent.code,
                       parent.level,
                       parent.manager_id,
                       child.depth + 1
                FROM departments parent
                JOIN ancestors child ON child.parent_id = parent.id
                WHERE parent.is_deleted = false
            ),
            company_office AS (
                SELECT office.id
                FROM departments office
                JOIN departments company ON company.id = office.parent_id
                JOIN employees manager ON manager.id = :employeeId
                WHERE office.code = 'GM'
                  AND office.manager_id = :employeeId
                  AND office.is_deleted = false
                  AND office.level IN ('管理中心', '一级部门', '二级班组', '三级科室')
                  AND manager.department_id = office.id
                  AND manager.is_deleted = false
                  AND manager.status IN ('active', 'probation', 'onLeave')
                  AND company.is_deleted = false
                  AND company.level = '公司'
                  AND company.parent_id IS NULL
            ),
            authority AS (
                SELECT office.id, 0 AS priority, 0 AS depth
                FROM company_office office
                UNION ALL
                SELECT ancestor.id, 1 AS priority, ancestor.depth
                FROM ancestors ancestor
                WHERE ancestor.manager_id = :employeeId
                  AND ancestor.code <> 'GM'
                  AND ancestor.level IN ('管理中心', '一级部门', '二级班组', '三级科室')
            )
            SELECT id
            FROM authority
            ORDER BY priority, depth
            LIMIT 1
            """, nativeQuery = true)
    Optional<UUID> findManagerScopeDepartmentId(
            @Param("departmentId") UUID departmentId,
            @Param("employeeId") UUID employeeId);

    /**
     * Active descendants of every non-GM manager_id authority root. Canonical
     * GM company scope is resolved separately with direct-membership and company
     * root checks. Position names never participate.
     */
    @Query(value = """
            WITH RECURSIVE managed(id) AS (
                SELECT id
                FROM departments
                WHERE manager_id = :employeeId
                  AND is_deleted = false
                  AND code <> 'GM'
                  AND level IN ('管理中心', '一级部门', '二级班组', '三级科室')
                UNION
                SELECT child.id
                FROM departments child
                JOIN managed parent ON child.parent_id = parent.id
                WHERE child.is_deleted = false
            )
            SELECT department.*
            FROM departments department
            JOIN managed ON managed.id = department.id
            ORDER BY department.path, department.sort_order, department.name
            """, nativeQuery = true)
    List<Department> findManagedDepartments(@Param("employeeId") UUID employeeId);

    /** 递归 CTE：返回某部门及其全部后代（含自身），仅未软删。 */
    @Query(value = """
            WITH RECURSIVE subtree AS (
                SELECT id FROM departments WHERE id = :rootId AND is_deleted = false
                UNION ALL
                SELECT d.id FROM departments d
                JOIN subtree s ON d.parent_id = s.id
                WHERE d.is_deleted = false
            )
            SELECT d.* FROM departments d
            WHERE d.id IN (SELECT id FROM subtree)
            ORDER BY d.path
            """, nativeQuery = true)
    List<Department> findSubtree(@Param("rootId") UUID rootId);

    /** 判断 candidate 是否为 root 的（含自身）后代——用于部门防成环校验。 */
    @Query(value = """
            WITH RECURSIVE subtree AS (
                SELECT id FROM departments WHERE id = :rootId
                UNION ALL
                SELECT d.id FROM departments d JOIN subtree s ON d.parent_id = s.id
            )
            SELECT EXISTS(SELECT 1 FROM subtree WHERE id = :candidate)
            """, nativeQuery = true)
    boolean isDescendant(@Param("rootId") UUID rootId, @Param("candidate") UUID candidate);

    /**
     * 按当前 parent_id 一次性重建移动子树的语义层级和物化路径。
     *
     * <p>path 触发器只处理 parent_id/code 发生 UPDATE 的当前行；该 CTE 显式更新
     * 后代 path，且不依赖移动前的旧 path 排序。服务层在防环检查前用事务级 advisory lock
     * 串行化层级变更；该 UPDATE 负责在一次语句内写入并锁定本次子树行。
     */
    @Modifying(flushAutomatically = true, clearAutomatically = true)
    @Query(value = """
            WITH RECURSIVE rebuilt(id, new_level, new_path, visited) AS (
                SELECT d.id,
                       CASE
                           WHEN p.id IS NULL THEN '一级部门'
                           WHEN p.level IN ('公司', '决策层', '管理中心') THEN '一级部门'
                           WHEN p.level = '一级部门' THEN '二级班组'
                           WHEN p.level IN ('二级班组', '三级科室') THEN '三级科室'
                           ELSE '二级班组'
                       END::text,
                       CASE
                           WHEN p.id IS NULL THEN '/' || d.code || '/'
                           ELSE COALESCE(p.path, '/') || d.code || '/'
                       END::text,
                       ARRAY[d.id]
                FROM departments d
                LEFT JOIN departments p ON p.id = d.parent_id
                WHERE d.id = :rootId AND d.is_deleted = false

                UNION ALL

                SELECT child.id,
                       CASE
                           WHEN parent.new_level = '一级部门' THEN '二级班组'
                           WHEN parent.new_level IN ('二级班组', '三级科室') THEN '三级科室'
                           ELSE '一级部门'
                       END::text,
                       (parent.new_path || child.code || '/')::text,
                       parent.visited || child.id
                FROM departments child
                JOIN rebuilt parent ON child.parent_id = parent.id
                WHERE NOT child.id = ANY(parent.visited)
            )
            UPDATE departments d
            SET level = rebuilt.new_level,
                path = rebuilt.new_path,
                updated_by = COALESCE(
                    NULLIF(current_setting('app.actor_id', true), '')::uuid,
                    d.updated_by
                )
            FROM rebuilt
            WHERE d.id = rebuilt.id
            """, nativeQuery = true)
    int rebuildSubtreeHierarchy(@Param("rootId") UUID rootId);
}
