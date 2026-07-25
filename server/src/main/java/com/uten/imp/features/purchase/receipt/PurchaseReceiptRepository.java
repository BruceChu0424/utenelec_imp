package com.uten.imp.features.purchase.receipt;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/**
 * 采购收货单主表仓库。列表用 {@link JpaSpecificationExecutor} 动态筛选。
 */
public interface PurchaseReceiptRepository
        extends JpaRepository<PurchaseReceipt, UUID>, JpaSpecificationExecutor<PurchaseReceipt> {

    Optional<PurchaseReceipt> findByLegacyId(Integer legacyId);
}
