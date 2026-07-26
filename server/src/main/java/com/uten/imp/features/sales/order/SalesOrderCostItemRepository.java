package com.uten.imp.features.sales.order;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Collection;
import java.util.List;
import java.util.UUID;

/**
 * 销售订单 BOM 展开仓库。本期 Java 只读（迁移原样落，design 20 §一·13）；
 * update 主单时连带清理所属明细的 cost items（随明细级联）。
 */
public interface SalesOrderCostItemRepository extends JpaRepository<SalesOrderCostItem, UUID> {

    /** 按订单明细 id 列表批量查（订单详情一次取出，避免 N+1）。 */
    List<SalesOrderCostItem> findByOrderItemIdIn(Collection<UUID> orderItemIds);

    @Modifying
    @Query("DELETE FROM SalesOrderCostItem c WHERE c.orderItemId IN "
            + "(SELECT i.id FROM SalesOrderItem i WHERE i.orderId = :oid)")
    void deleteByOrderId(@Param("oid") UUID orderId);
}
