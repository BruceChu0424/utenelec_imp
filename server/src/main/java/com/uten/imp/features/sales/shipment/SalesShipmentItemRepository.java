package com.uten.imp.features.sales.shipment;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/** 销售出货明细仓库。 */
public interface SalesShipmentItemRepository extends JpaRepository<SalesShipmentItem, UUID> {

    @Query("SELECT i FROM SalesShipmentItem i WHERE i.shipmentId = :shipmentId AND i.deleted = false ORDER BY i.lineNo, i.id")
    List<SalesShipmentItem> findByShipmentIdOrderByLineNoAsc(@Param("shipmentId") UUID shipmentId);

    @Modifying
    @Query("DELETE FROM SalesShipmentItem i WHERE i.shipmentId = :sid")
    void deleteByShipmentId(@Param("sid") UUID shipmentId);
}
