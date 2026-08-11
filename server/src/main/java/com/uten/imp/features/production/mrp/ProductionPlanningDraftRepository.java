package com.uten.imp.features.production.mrp;

import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;
import java.util.UUID;

public interface ProductionPlanningDraftRepository
        extends JpaRepository<ProductionPlanningDraft, UUID> {

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("""
            SELECT draft
            FROM ProductionPlanningDraft draft
            WHERE draft.planId = :planId
              AND draft.status = 'ACTIVE'
            """)
    Optional<ProductionPlanningDraft> lockActiveByPlanId(
            @Param("planId") UUID planId);

    Optional<ProductionPlanningDraft> findByPlanIdAndStatus(
            UUID planId, String status);
}
