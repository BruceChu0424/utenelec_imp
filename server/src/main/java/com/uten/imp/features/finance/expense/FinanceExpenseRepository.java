package com.uten.imp.features.finance.expense;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/** 一般费用单主表仓库。 */
public interface FinanceExpenseRepository
        extends JpaRepository<FinanceExpense, UUID>, JpaSpecificationExecutor<FinanceExpense> {

    Optional<FinanceExpense> findByLegacyId(Integer legacyId);

    Optional<FinanceExpense> findByBillNo(String billNo);
}
