package com.uten.imp.features.finance.receipt;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/** 销售收款核销明细仓库。明细独立管理（update 时物理删旧 + 插新，避免 @OneToMany 软删+cascade 坑）。 */
public interface FinanceReceiptLineRepository extends JpaRepository<FinanceReceiptLine, UUID> {

    List<FinanceReceiptLine> findByReceiptIdOrderByLineNoAsc(UUID receiptId);

    @Modifying
    @Query("DELETE FROM FinanceReceiptLine l WHERE l.receiptId = :rid")
    void deleteByReceiptId(@Param("rid") UUID receiptId);
}
