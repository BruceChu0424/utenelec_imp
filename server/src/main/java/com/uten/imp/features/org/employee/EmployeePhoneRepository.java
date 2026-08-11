package com.uten.imp.features.org.employee;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface EmployeePhoneRepository extends JpaRepository<EmployeePhone, UUID> {

    List<EmployeePhone> findByEmployeeIdOrderBySortOrderAsc(UUID employeeId);

    void deleteByEmployeeId(UUID employeeId);
}
