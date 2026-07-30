package com.uten.imp.features.sales.shipment;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/** 销售出货单主表仓库。 */
public interface SalesShipmentRepository
        extends JpaRepository<SalesShipment, UUID>, JpaSpecificationExecutor<SalesShipment> {

    Optional<SalesShipment> findByLegacyId(Integer legacyId);
}
