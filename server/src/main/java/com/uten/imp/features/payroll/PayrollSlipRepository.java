package com.uten.imp.features.payroll;

import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.Instant;
import java.util.Collection;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface PayrollSlipRepository
        extends JpaRepository<PayrollSlip, UUID>, JpaSpecificationExecutor<PayrollSlip> {

    List<PayrollSlip> findByBatchIdOrderByEmployeeCodeSnapshotAscIdAsc(UUID batchId);

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("SELECT s FROM PayrollSlip s WHERE s.id = :id")
    Optional<PayrollSlip> findByIdForUpdate(@Param("id") UUID id);

    @Query("""
            SELECT COUNT(s) FROM PayrollSlip s
            WHERE s.active = true
              AND s.payrollYear = :year
              AND s.payrollMonth = :month
              AND s.employeeId IN :employeeIds
            """)
    long countActiveConflicts(@Param("year") short year,
                              @Param("month") short month,
                              @Param("employeeIds") Collection<UUID> employeeIds);

    @Modifying(clearAutomatically = true, flushAutomatically = true)
    @Query("UPDATE PayrollSlip s SET s.active = false WHERE s.batchId = :batchId AND s.active = true")
    int deactivateBatch(@Param("batchId") UUID batchId);

    @Modifying(clearAutomatically = true, flushAutomatically = true)
    @Query("""
            UPDATE PayrollSlip s
            SET s.status = 'PUBLISHED', s.publishedAt = :publishedAt
            WHERE s.batchId = :batchId AND s.active = true AND s.status = 'PENDING'
            """)
    int publishBatch(@Param("batchId") UUID batchId, @Param("publishedAt") Instant publishedAt);
}
