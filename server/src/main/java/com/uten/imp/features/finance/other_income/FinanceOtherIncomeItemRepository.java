package com.uten.imp.features.finance.other_income;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/** 其它收入明细仓库。 */
public interface FinanceOtherIncomeItemRepository extends JpaRepository<FinanceOtherIncomeItem, UUID> {

    List<FinanceOtherIncomeItem> findByIncomeIdOrderByLineNoAsc(UUID incomeId);

    @Modifying
    @Query("DELETE FROM FinanceOtherIncomeItem i WHERE i.incomeId = :iid")
    void deleteByIncomeId(@Param("iid") UUID incomeId);
}
