package com.uten.imp.features.org.employee;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

public interface EmployeeRepository extends JpaRepository<Employee, UUID>, JpaSpecificationExecutor<Employee> {

    Optional<Employee> findByCode(String code);

    boolean existsByCode(String code);

    long countByDepartmentIdAndDeletedFalse(UUID departmentId);
}
