package com.uten.imp.features.finance.bank_transfer;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/** 银行存取款明细仓库。 */
public interface FinanceBankTransferLineRepository extends JpaRepository<FinanceBankTransferLine, UUID> {

    List<FinanceBankTransferLine> findByTransferIdOrderByLineNoAsc(UUID transferId);

    @Modifying
    @Query("DELETE FROM FinanceBankTransferLine l WHERE l.transferId = :tid")
    void deleteByTransferId(@Param("tid") UUID transferId);
}
