package com.uten.imp.features.sales.order;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/** 销售订货单主表仓库。 */
public interface SalesOrderRepository
        extends JpaRepository<SalesOrder, UUID>, JpaSpecificationExecutor<SalesOrder> {

    Optional<SalesOrder> findByLegacyId(Integer legacyId);
}
