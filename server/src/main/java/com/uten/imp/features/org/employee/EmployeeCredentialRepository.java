package com.uten.imp.features.org.employee;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface EmployeeCredentialRepository extends JpaRepository<EmployeeCredential, UUID> {

    List<EmployeeCredential> findByEmployeeId(UUID employeeId);
    List<EmployeeCredential> findByEmployeeIdIn(java.util.Collection<UUID> employeeIds);

    void deleteByEmployeeId(UUID employeeId);
}
