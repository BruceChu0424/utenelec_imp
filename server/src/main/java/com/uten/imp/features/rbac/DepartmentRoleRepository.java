package com.uten.imp.features.rbac;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface DepartmentRoleRepository extends JpaRepository<DepartmentRole, DepartmentRoleId> {

    /** 取某部门默认角色的 role_id 列表（权限合成用）。 */
    @Query(value = """
            SELECT dr.role_id FROM department_roles dr WHERE dr.department_id = :departmentId
            """, nativeQuery = true)
    List<UUID> findRoleIdsByDepartmentId(@Param("departmentId") UUID departmentId);

    /** 全量部门默认角色（department_id, role_code），管理端列表用。 */
    @Query(value = """
            SELECT dr.department_id, r.code
            FROM department_roles dr
            JOIN roles r ON r.id = dr.role_id
            """, nativeQuery = true)
    List<Object[]> findAllDepartmentRoleCodes();

    void deleteByIdDepartmentId(UUID departmentId);
}
