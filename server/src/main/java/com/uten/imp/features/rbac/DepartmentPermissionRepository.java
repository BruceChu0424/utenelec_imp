package com.uten.imp.features.rbac;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface DepartmentPermissionRepository extends JpaRepository<DepartmentPermission, DepartmentPermissionId> {

    /** 取某部门直配权限点的 code 列表（权限合成与管理端查询共用）。 */
    @Query(value = """
            SELECT p.code
            FROM department_permissions dp
            JOIN permissions p ON p.id = dp.permission_id
            WHERE dp.department_id = :departmentId
              AND p.active = TRUE
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
            WHERE p.active = TRUE
            """, nativeQuery = true)
    List<String> findPermissionCodesByDepartmentIdWithAncestors(@Param("departmentId") UUID departmentId);

    void deleteByIdDepartmentId(UUID departmentId);
}
