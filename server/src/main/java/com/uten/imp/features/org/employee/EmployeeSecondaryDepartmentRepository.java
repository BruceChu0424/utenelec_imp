package com.uten.imp.features.org.employee;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface EmployeeSecondaryDepartmentRepository
        extends JpaRepository<EmployeeSecondaryDepartment, UUID> {

    List<EmployeeSecondaryDepartment> findByEmployeeIdOrderByCreatedAtAscIdAsc(UUID employeeId);

    /** 权限合成：员工全部兼职部门 id（不含主部门）。 */
    @Query("""
            SELECT DISTINCT s.departmentId
            FROM EmployeeSecondaryDepartment s
            WHERE s.employeeId = :employeeId
            """)
    List<UUID> findDepartmentIdsByEmployeeId(@Param("employeeId") UUID employeeId);

    /** 员工是否兼任某部门（定向资格判定）。 */
    boolean existsByEmployeeIdAndDepartmentId(UUID employeeId, UUID departmentId);

    /** 调岗联动：新主部门若在兼职列表中必须先移除，否则 not_primary 触发器拒绝。 */
    @Modifying
    @Query("""
            DELETE FROM EmployeeSecondaryDepartment s
            WHERE s.employeeId = :employeeId
              AND s.departmentId = :departmentId
            """)
    int deleteByEmployeeIdAndDepartmentId(
            @Param("employeeId") UUID employeeId,
            @Param("departmentId") UUID departmentId);

    /** 编辑页全量替换：先清后写，兼职行级变更由触发器吊销旧 token。 */
    @Modifying
    @Query("DELETE FROM EmployeeSecondaryDepartment s WHERE s.employeeId = :employeeId")
    int deleteAllByEmployeeId(@Param("employeeId") UUID employeeId);
}
