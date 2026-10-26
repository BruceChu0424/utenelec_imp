package com.uten.imp.features.org.employee;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import jakarta.persistence.LockModeType;

import java.util.List;
import java.util.UUID;
import java.util.Optional;

public interface EmployeeContractRepository extends JpaRepository<EmployeeContract, UUID> {
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("SELECT contract FROM EmployeeContract contract WHERE contract.id=:id")
    Optional<EmployeeContract> findByIdForUpdate(@Param("id") UUID id);

    List<EmployeeContract> findByEmployeeIdOrderBySignOrderAsc(UUID employeeId);

    long countByEmployeeId(UUID employeeId);
}
