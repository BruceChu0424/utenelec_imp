package com.uten.imp.features.production.plan;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface ProductionPlanItemRepository extends JpaRepository<ProductionPlanItem, UUID> {

    List<ProductionPlanItem> findByPlanIdOrderByLineNoAsc(UUID planId);

    @Modifying
    @Query("DELETE FROM ProductionPlanItem i WHERE i.planId = :pid")
    void deleteByPlanId(@Param("pid") UUID planId);
}
