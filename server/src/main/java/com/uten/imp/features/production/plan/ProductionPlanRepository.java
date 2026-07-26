package com.uten.imp.features.production.plan;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

public interface ProductionPlanRepository
        extends JpaRepository<ProductionPlan, UUID>, JpaSpecificationExecutor<ProductionPlan> {

    Optional<ProductionPlan> findByLegacyId(Integer legacyId);
}
