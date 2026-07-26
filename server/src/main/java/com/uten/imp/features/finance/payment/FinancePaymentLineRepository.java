package com.uten.imp.features.finance.payment;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/** 采购付款核销明细仓库（独立管理，update 时物理删旧 + 插新）。 */
public interface FinancePaymentLineRepository extends JpaRepository<FinancePaymentLine, UUID> {

    List<FinancePaymentLine> findByPaymentIdOrderByLineNoAsc(UUID paymentId);

    @Modifying
    @Query("DELETE FROM FinancePaymentLine l WHERE l.paymentId = :pid")
    void deleteByPaymentId(@Param("pid") UUID paymentId);
}
