package com.uten.imp.features.production.plan;

import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;
import java.util.UUID;

public interface ProductionPlanRepository
        extends JpaRepository<ProductionPlan, UUID>, JpaSpecificationExecutor<ProductionPlan> {

    Optional<ProductionPlan> findByLegacyId(Integer legacyId);

    @Lock(LockModeType.PESSIMISTIC_READ)
    @Query("""
            SELECT p
            FROM ProductionPlan p
            WHERE p.id = :id
              AND p.deleted = false
            """)
    Optional<ProductionPlan> lockForWorkCard(@Param("id") UUID id);
}
