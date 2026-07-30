package com.uten.imp.features.sales.other_shipment;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/** 其它出货单主表仓库。 */
public interface SalesOtherShipmentRepository
        extends JpaRepository<SalesOtherShipment, UUID>, JpaSpecificationExecutor<SalesOtherShipment> {

    Optional<SalesOtherShipment> findByLegacyId(Integer legacyId);
}
