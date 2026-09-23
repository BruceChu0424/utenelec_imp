package com.uten.imp.features.rbac;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Collection;
import java.util.List;
import java.util.UUID;

public interface DepartmentPermissionRepository extends JpaRepository<DepartmentPermission, DepartmentPermissionId> {

    /** 取某部门直配权限点的 code 列表（权限合成与管理端查询共用）。 */
    @Query(value = """
            SELECT p.code
            FROM department_permissions dp
            JOIN permissions p ON p.id = dp.permission_id
            WHERE dp.department_id = :departmentId
            """, nativeQuery = true)
    List<String> findPermissionCodesByDepartmentId(@Param("departmentId") UUID departmentId);

    /**
     * 取某部门及其所有上级部门的直配权限点 code 并集（递归 CTE 沿 parent 链向上）。
     * 用于权限合成：上级部门的配置对下级部门员工生效。
     */
    @Query(value = """
            WITH RECURSIVE ancestors AS (
                SELECT id, parent_id FROM departments WHERE id = :departmentId
                UNION ALL
                SELECT d.id, d.parent_id
                FROM departments d
                JOIN ancestors a ON d.id = a.parent_id
            )
            SELECT DISTINCT p.code
            FROM department_permissions dp
            JOIN permissions p ON p.id = dp.permission_id
            JOIN ancestors a ON a.id = dp.department_id
            """, nativeQuery = true)
    List<String> findPermissionCodesByDepartmentIdWithAncestors(@Param("departmentId") UUID departmentId);

    /**
     * 多部门版本（V459 兼职并入）：主部门 + 各兼职部门，每个部门沿 parent 链
     * 向上递归取并集。一条 SQL 服务权限合成，避免逐部门懒查询。
     */
    @Query(value = """
            WITH RECURSIVE ancestors AS (
                SELECT d.id, d.parent_id
                FROM departments d
                WHERE d.id IN (:departmentIds)
                UNION
                SELECT d.id, d.parent_id
                FROM departments d
                JOIN ancestors a ON d.id = a.parent_id
            )
            SELECT DISTINCT p.code
            FROM department_permissions dp
            JOIN permissions p ON p.id = dp.permission_id
            JOIN ancestors a ON a.id = dp.department_id
            """, nativeQuery = true)
    List<String> findPermissionCodesByDepartmentIdsWithAncestors(
            @Param("departmentIds") List<UUID> departmentIds);

    /**
     * 串行化同一部门矩阵的保存：先锁部门行再读现有授权。两个超管同时保存时，后到者等先到者
     * 提交后再读，算出的 added/removed 与真实写入一致。FOR NO KEY UPDATE 只与同类锁互斥，
     * 不挡其它表对部门的外键检查。部门不存在或已删除时返回空。
     */
    @Query(value = """
            SELECT CAST(id AS text) FROM departments
            WHERE id = :departmentId AND is_deleted = FALSE
            FOR NO KEY UPDATE
            """, nativeQuery = true)
    java.util.Optional<String> lockLiveDepartment(@Param("departmentId") UUID departmentId);

    /** 差量授予：一条语句插入本次新增的码(已存在的行不动)。 */
    @Modifying(flushAutomatically = true)
    @Query(value = """
            INSERT INTO department_permissions (department_id, permission_id, created_by)
            SELECT :departmentId, permission.id, :actor
            FROM permissions permission
            WHERE permission.code IN (:codes)
            ON CONFLICT DO NOTHING
            """, nativeQuery = true)
    int insertGrants(@Param("departmentId") UUID departmentId,
                     @Param("codes") Collection<String> codes,
                     @Param("actor") UUID actor);

    /** 差量收回：只删本次取消的行(保存无改动时 0 行写入、0 行审计)。 */
    @Modifying(flushAutomatically = true)
    @Query(value = """
            DELETE FROM department_permissions
            WHERE department_id = :departmentId
              AND permission_id IN (:permissionIds)
            """, nativeQuery = true)
    int deleteGrants(@Param("departmentId") UUID departmentId,
                     @Param("permissionIds") Collection<UUID> permissionIds);
}
