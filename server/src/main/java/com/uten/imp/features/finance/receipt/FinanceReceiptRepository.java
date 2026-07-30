package com.uten.imp.features.finance.receipt;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/** 销售收款单主表仓库。列表用 {@link JpaSpecificationExecutor} 动态筛选。 */
public interface FinanceReceiptRepository
        extends JpaRepository<FinanceReceipt, UUID>, JpaSpecificationExecutor<FinanceReceipt> {

    Optional<FinanceReceipt> findByLegacyId(Integer legacyId);

    Optional<FinanceReceipt> findByBillNo(String billNo);
}
