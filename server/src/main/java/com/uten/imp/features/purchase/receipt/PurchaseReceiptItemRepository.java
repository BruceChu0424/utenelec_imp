package com.uten.imp.features.purchase.receipt;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/**
 * 采购收货明细仓库。明细独立管理（不走主表 @OneToMany）。
 */
public interface PurchaseReceiptItemRepository extends JpaRepository<PurchaseReceiptItem, UUID> {

    List<PurchaseReceiptItem> findByReceiptIdOrderByLineNoAsc(UUID receiptId);

    @Modifying
    @Query("DELETE FROM PurchaseReceiptItem i WHERE i.receiptId = :rid")
    void deleteByReceiptId(@Param("rid") UUID receiptId);
}
