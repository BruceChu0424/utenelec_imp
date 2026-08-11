package com.uten.imp.features.org.employee;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface EmploymentHistoryRepository extends JpaRepository<EmploymentHistory, UUID> {

    List<EmploymentHistory> findByEmployeeIdOrderByEventDateDesc(UUID employeeId);

    Optional<EmploymentHistory>
    findFirstByEmployeeIdOrderByEventDateDescCreatedAtDesc(UUID employeeId);
}
