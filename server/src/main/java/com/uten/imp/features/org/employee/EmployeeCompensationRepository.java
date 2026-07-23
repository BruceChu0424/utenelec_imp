package com.uten.imp.features.org.employee;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;
import java.util.UUID;

public interface EmployeeCompensationRepository extends JpaRepository<EmployeeCompensation, UUID> {

    Optional<EmployeeCompensation> findByEmployeeId(UUID employeeId);
}
