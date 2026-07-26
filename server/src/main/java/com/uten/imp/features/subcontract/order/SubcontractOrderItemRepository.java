package com.uten.imp.features.subcontract.order;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/** 委外订货明细仓库。明细独立管理（不走主表 @OneToMany，规避软删+cascade 坑）。 */
public interface SubcontractOrderItemRepository extends JpaRepository<SubcontractOrderItem, UUID> {

    List<SubcontractOrderItem> findByOrderIdOrderByLineNoAsc(UUID orderId);

    @Modifying
    @Query("DELETE FROM SubcontractOrderItem i WHERE i.orderId = :oid")
    void deleteByOrderId(@Param("oid") UUID orderId);
}
