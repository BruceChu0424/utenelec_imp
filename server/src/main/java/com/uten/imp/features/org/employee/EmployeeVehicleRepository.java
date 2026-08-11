package com.uten.imp.features.org.employee;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface EmployeeVehicleRepository extends JpaRepository<EmployeeVehicle, UUID> {

    List<EmployeeVehicle> findByEmployeeIdOrderBySortOrderAsc(UUID employeeId);

    void deleteByEmployeeId(UUID employeeId);

    boolean existsByEmployeeIdAndPlateNorm(UUID employeeId, String plateNorm);
}
