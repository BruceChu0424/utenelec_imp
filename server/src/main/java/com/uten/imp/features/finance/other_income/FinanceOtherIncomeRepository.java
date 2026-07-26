package com.uten.imp.features.finance.other_income;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/** 其它收入单主表仓库。 */
public interface FinanceOtherIncomeRepository
        extends JpaRepository<FinanceOtherIncome, UUID>, JpaSpecificationExecutor<FinanceOtherIncome> {

    Optional<FinanceOtherIncome> findByLegacyId(Integer legacyId);

    Optional<FinanceOtherIncome> findByBillNo(String billNo);
}
