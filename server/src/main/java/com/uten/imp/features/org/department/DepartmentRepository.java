package com.uten.imp.features.org.department;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface DepartmentRepository extends JpaRepository<Department, UUID> {

    boolean existsByCode(String code);

    Optional<Department> findByCodeAndDeletedFalse(String code);

    List<Department> findByParentIdOrderBySortOrderAscNameAsc(UUID parentId);

    List<Department> findByManagerId(UUID managerId);

    List<Department> findByDeletedFalseOrderBySortOrderAscNameAsc();

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
     * 判断目标组织是否落在当前负责人允许管理的范围内。
     *
     * <p>普通部门负责人维持既有“仅本部门”边界；管理中心负责人可管理中心本身及全部后代。
     * 岗位名称和职级不参与授权，唯一事实来源是 {@code departments.manager_id}。
     */
    @Query(value = """
            WITH RECURSIVE ancestors AS (
                SELECT id, parent_id, level, manager_id
                FROM departments
                WHERE id = :departmentId AND is_deleted = false
                UNION ALL
                SELECT parent.id, parent.parent_id, parent.level, parent.manager_id
                FROM departments parent
                JOIN ancestors child ON child.parent_id = parent.id
                WHERE parent.is_deleted = false
            )
            SELECT EXISTS(
                SELECT 1
                FROM ancestors
                WHERE manager_id = :employeeId
                  AND (
                      id = :departmentId
                      OR level = '管理中心'
                  )
            )
            """, nativeQuery = true)
    boolean isWithinManagerScope(
            @Param("departmentId") UUID departmentId,
            @Param("employeeId") UUID employeeId);

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
