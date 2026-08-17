package com.uten.imp.features.org.employee;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.EntityGraph;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.util.Collection;
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

    /** 部门主管的"本部门员工"面板用：本部门（不含子部门）在册员工。 */
    @EntityGraph(attributePaths = {"position"})
    List<Employee> findByDepartmentIdAndDeletedFalseOrderByFullNameAsc(UUID departmentId);

    /**
     * "我的部门"通讯录用：某部门子树（含自身 + 所有下级部门）下全部在册员工。
     * 用途：管理中心/一级部门等纯分组节点本身不挂人，其员工都在下层部门；
     * 通讯录按子树聚合才能让分组节点也显示人员。
     */
    @EntityGraph(attributePaths = {"position", "department"})
    List<Employee> findByDepartmentIdInAndDeletedFalseOrderByFullNameAsc(
            Collection<UUID> departmentIds);

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
     * 开通账号候选：在册（未删除、非离职）且尚无未删除登录账号的员工。
     * 按姓名/工号模糊搜索（空串不过滤），按工号排序；调用方传 Pageable 限量。
     * 用途：权限设置页「开通账号」选择器（account:support），不回传任何 PII。
     */
    @Query("""
            SELECT e
            FROM Employee e
            LEFT JOIN FETCH e.department
            WHERE e.deleted = false
              AND e.status <> 'resigned'
              AND NOT EXISTS (
                  SELECT 1 FROM UserAccount u
                  WHERE u.employeeId = e.id AND u.deleted = false)
              AND (:search IS NULL OR :search = ''
                   OR LOWER(e.fullName) LIKE LOWER(CONCAT('%', :search, '%'))
                   OR LOWER(e.code) LIKE LOWER(CONCAT('%', :search, '%')))
            ORDER BY e.code ASC
            """)
    List<Employee> findProvisionCandidates(@Param("search") String search, Pageable pageable);

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
