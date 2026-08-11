package com.uten.imp.features.payroll;

import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;
import java.util.UUID;

public interface PayrollBatchRepository
        extends JpaRepository<PayrollBatch, UUID>, JpaSpecificationExecutor<PayrollBatch> {

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("SELECT b FROM PayrollBatch b WHERE b.id = :id")
    Optional<PayrollBatch> findByIdForUpdate(@Param("id") UUID id);
}
