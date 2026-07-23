package com.uten.imp.features.org.employee;

import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Collection;
import java.util.Optional;
import java.util.UUID;

public interface EmployeeRepository extends JpaRepository<Employee, UUID>, JpaSpecificationExecutor<Employee> {

    Optional<Employee> findByCode(String code);

    boolean existsByCode(String code);

    /** 按一组部门（子树）分页列出在职未软删员工。 */
    Page<Employee> findByDepartmentIdInAndDeletedFalse(Collection<UUID> departmentIds, Pageable pageable);

    Page<Employee> findByDeletedFalse(Pageable pageable);

    long countByDepartmentIdAndDeletedFalse(UUID departmentId);

    long countByDepartmentIdInAndDeletedFalse(Collection<UUID> departmentIds);
}
