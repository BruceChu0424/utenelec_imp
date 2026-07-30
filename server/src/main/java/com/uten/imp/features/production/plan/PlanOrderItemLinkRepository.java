package com.uten.imp.features.production.plan;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

/** 计划×订单联动仓库（V90）。 */
public interface PlanOrderItemLinkRepository extends JpaRepository<PlanOrderItemLink, UUID> {

    Optional<PlanOrderItemLink> findByPlanItemIdAndOrderItemIdAndDeletedFalse(UUID planItemId, UUID orderItemId);

    @Query("SELECT l FROM PlanOrderItemLink l WHERE l.planItemId IN :planItemIds AND l.deleted = false")
    List<PlanOrderItemLink> findActiveByPlanItemIds(@Param("planItemIds") List<UUID> planItemIds);

    @Query("SELECT l FROM PlanOrderItemLink l WHERE l.orderItemId = :orderItemId AND l.deleted = false")
    List<PlanOrderItemLink> findActiveByOrderItemId(@Param("orderItemId") UUID orderItemId);
}
