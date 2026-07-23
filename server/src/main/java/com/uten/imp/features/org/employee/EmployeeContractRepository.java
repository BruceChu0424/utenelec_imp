package com.uten.imp.features.org.employee;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface EmployeeContractRepository extends JpaRepository<EmployeeContract, UUID> {

    List<EmployeeContract> findByEmployeeIdOrderBySignOrderAsc(UUID employeeId);

    long countByEmployeeId(UUID employeeId);
}
