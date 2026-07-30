package com.uten.imp.features.subcontract.receipt;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/** 委外进仓明细仓库。明细独立管理（不走主表 @OneToMany，规避软删+cascade 坑）。 */
public interface SubcontractReceiptItemRepository extends JpaRepository<SubcontractReceiptItem, UUID> {

    List<SubcontractReceiptItem> findByReceiptIdOrderByLineNoAsc(UUID receiptId);

    @Modifying
    @Query("DELETE FROM SubcontractReceiptItem i WHERE i.receiptId = :rid")
    void deleteByReceiptId(@Param("rid") UUID receiptId);
}
