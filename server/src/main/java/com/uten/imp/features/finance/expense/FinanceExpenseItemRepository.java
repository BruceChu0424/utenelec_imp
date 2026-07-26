package com.uten.imp.features.finance.expense;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/** 一般费用明细仓库（独立管理，update 时物理删旧 + 插新）。 */
public interface FinanceExpenseItemRepository extends JpaRepository<FinanceExpenseItem, UUID> {

    List<FinanceExpenseItem> findByExpenseIdOrderByLineNoAsc(UUID expenseId);

    @Modifying
    @Query("DELETE FROM FinanceExpenseItem i WHERE i.expenseId = :eid")
    void deleteByExpenseId(@Param("eid") UUID expenseId);
}
