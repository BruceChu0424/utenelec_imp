package com.uten.imp.features.production.fulfillment;

import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;
import java.util.UUID;

public interface ProductionPlanningPackageRepository
        extends JpaRepository<ProductionPlanningPackage, UUID> {

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("""
            SELECT p
            FROM ProductionPlanningPackage p
            WHERE p.planId = :planId
              AND p.idempotencyKey = :key
              AND p.deleted = false
            """)
    Optional<ProductionPlanningPackage> lockByPlanAndKey(
            @Param("planId") UUID planId,
            @Param("key") String key);

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("""
            SELECT p
            FROM ProductionPlanningPackage p
            WHERE p.planId = :planId
              AND p.status = 'CONFIRMED'
              AND p.deleted = false
            """)
    Optional<ProductionPlanningPackage> lockConfirmedByPlan(
            @Param("planId") UUID planId);

    @Lock(LockModeType.PESSIMISTIC_READ)
    Optional<ProductionPlanningPackage>
            findFirstByPlanIdAndStatusAndExecutionModelVersionAndDeletedFalseOrderByCreatedAtDesc(
                    UUID planId,
                    String status,
                    Short executionModelVersion);
    @Lock(LockModeType.PESSIMISTIC_READ)
    @Query("""
            SELECT p
            FROM ProductionPlanningPackage p
            WHERE p.id = :packageId
              AND p.planId = :planId
              AND p.status = 'CONFIRMED'
              AND p.executionModelVersion = 1
              AND p.deleted = false
            """)
    Optional<ProductionPlanningPackage> lockConfirmedExecutionPackage(
            @Param("planId") UUID planId,
            @Param("packageId") UUID packageId);
}
