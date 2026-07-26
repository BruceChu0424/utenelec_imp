package com.uten.imp.features.sales.order;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/** 销售订货明细仓库（明细独立管理）。 */
public interface SalesOrderItemRepository extends JpaRepository<SalesOrderItem, UUID> {

    List<SalesOrderItem> findByOrderIdOrderByLineNoAsc(UUID orderId);

    @Modifying
    @Query("DELETE FROM SalesOrderItem i WHERE i.orderId = :oid")
    void deleteByOrderId(@Param("oid") UUID orderId);
}
