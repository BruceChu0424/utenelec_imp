package com.uten.imp.features.finance.payment;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/** 采购付款单主表仓库。 */
public interface FinancePaymentRepository
        extends JpaRepository<FinancePayment, UUID>, JpaSpecificationExecutor<FinancePayment> {

    Optional<FinancePayment> findByLegacyId(Integer legacyId);

    Optional<FinancePayment> findByBillNo(String billNo);
}
