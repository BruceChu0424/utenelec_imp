package com.uten.imp.features.subcontract.order;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/** 委外订货单主表仓库。列表用 {@link JpaSpecificationExecutor} 动态筛选。 */
public interface SubcontractOrderRepository
        extends JpaRepository<SubcontractOrder, UUID>, JpaSpecificationExecutor<SubcontractOrder> {

    Optional<SubcontractOrder> findByLegacyId(Integer legacyId);
}
