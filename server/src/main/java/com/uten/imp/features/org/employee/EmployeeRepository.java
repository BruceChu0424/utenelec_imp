package com.uten.imp.features.org.employee;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface EmployeeRepository extends JpaRepository<Employee, UUID>, JpaSpecificationExecutor<Employee> {

    Optional<Employee> findByCode(String code);

    boolean existsByCode(String code);

    long countByDepartmentIdAndDeletedFalse(UUID departmentId);

    /**
     * 取某部门子树（含自身 + 所有下级部门）下全部员工的 user id。
     * 用途：部门权限配置变更后吊销这些用户的 refresh token，强制重新登录使新权限即时生效。
     */
    @Query(value = """
            WITH RECURSIVE sub AS (
                SELECT id FROM departments WHERE id = :departmentId
                UNION ALL
                SELECT d.id FROM departments d JOIN sub s ON d.parent_id = s.id
            )
            SELECT u.id FROM users u
            JOIN employees e ON e.id = u.employee_id
            WHERE e.department_id IN (SELECT id FROM sub)
            """, nativeQuery = true)
    List<UUID> findUserIdsByDepartmentSubtree(@Param("departmentId") UUID departmentId);
}
