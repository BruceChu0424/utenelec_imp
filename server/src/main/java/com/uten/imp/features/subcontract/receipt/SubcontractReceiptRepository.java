package com.uten.imp.features.subcontract.receipt;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/** 委外进仓单主表仓库。列表用 {@link JpaSpecificationExecutor} 动态筛选。 */
public interface SubcontractReceiptRepository
        extends JpaRepository<SubcontractReceipt, UUID>, JpaSpecificationExecutor<SubcontractReceipt> {

    Optional<SubcontractReceipt> findByLegacyId(Integer legacyId);
}
