package com.uten.imp.features.finance.bank_transfer;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/** 银行存取款单主表仓库（保结构/未来用）。 */
public interface FinanceBankTransferRepository
        extends JpaRepository<FinanceBankTransfer, UUID>, JpaSpecificationExecutor<FinanceBankTransfer> {

    Optional<FinanceBankTransfer> findByLegacyId(Integer legacyId);

    Optional<FinanceBankTransfer> findByBillNo(String billNo);
}
