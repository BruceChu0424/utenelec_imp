package com.uten.imp.features.org.employee;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface EmployeeEducationRepository extends JpaRepository<EmployeeEducation, UUID> {

    List<EmployeeEducation> findByEmployeeIdOrderByEndDateDesc(UUID employeeId);
    List<EmployeeEducation> findByEmployeeIdInOrderByEndDateDescIdAsc(java.util.Collection<UUID> employeeIds);

    void deleteByEmployeeId(UUID employeeId);
}
