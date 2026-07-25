package com.uten.imp.features.purchase.ret;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface PurchaseReturnItemRepository extends JpaRepository<PurchaseReturnItem, UUID> {
    List<PurchaseReturnItem> findByReturnIdOrderByLineNoAsc(UUID returnId);

    @Modifying
    @Query("DELETE FROM PurchaseReturnItem i WHERE i.returnId = :rid")
    void deleteByReturnId(@Param("rid") UUID returnId);
}
