package com.uten.imp.features.org.employee;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.EntityGraph;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

public interface EmployeeRepository extends JpaRepository<Employee, UUID>, JpaSpecificationExecutor<Employee> {

    /** Employee list pages commonly render the department name; fetch it in the page query. */
    @Override
    @EntityGraph(attributePaths = "department")
    Page<Employee> findAll(Specification<Employee> spec, Pageable pageable);

    Optional<Employee> findByCode(String code);

    boolean existsByCode(String code);

    long countByDepartmentIdAndDeletedFalse(UUID departmentId);

    long countByDepartmentIdAndDeletedFalseAndStatusIn(
            UUID departmentId, java.util.Collection<String> statuses);

    /**
     * 批量读取员工及其部门，供跨模块列表装配使用，避免逐行加载员工/部门的 N+1 查询。
     */
    @Query("""
            SELECT e
            FROM Employee e
            LEFT JOIN FETCH e.department
            WHERE e.id IN :ids
            """)
    List<Employee> findAllWithDepartmentByIdIn(@Param("ids") Set<UUID> ids);

    /**
     * 取某部门子树（含自身 + 所有下级部门）下全部员工的 user id。
     * 用途：部门权限配置变更后吊销这些用户的 refresh token，阻止旧权限继续续期。
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
