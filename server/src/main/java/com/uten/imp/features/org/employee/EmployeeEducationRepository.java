package com.uten.imp.features.org.employee;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface EmployeeEducationRepository extends JpaRepository<EmployeeEducation, UUID> {

    List<EmployeeEducation> findByEmployeeIdOrderByEndDateDesc(UUID employeeId);

    void deleteByEmployeeId(UUID employeeId);
}
