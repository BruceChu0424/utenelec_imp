package com.uten.imp.features.sales.other_shipment;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/** 其它出货明细仓库。 */
public interface SalesOtherShipmentItemRepository extends JpaRepository<SalesOtherShipmentItem, UUID> {

    List<SalesOtherShipmentItem> findByShipmentIdOrderByLineNoAsc(UUID shipmentId);

    @Modifying
    @Query("DELETE FROM SalesOtherShipmentItem i WHERE i.shipmentId = :sid")
    void deleteByShipmentId(@Param("sid") UUID shipmentId);
}
