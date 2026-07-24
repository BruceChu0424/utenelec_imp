package com.uten.imp.features.org.employee;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface EmergencyContactRepository extends JpaRepository<EmergencyContact, UUID> {

    List<EmergencyContact> findByEmployeeIdOrderBySortOrderAsc(UUID employeeId);
}
