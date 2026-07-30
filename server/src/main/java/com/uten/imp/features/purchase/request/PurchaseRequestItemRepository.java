package com.uten.imp.features.purchase.request;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface PurchaseRequestItemRepository extends JpaRepository<PurchaseRequestItem, UUID> {
    List<PurchaseRequestItem> findByRequestIdOrderByLineNoAsc(UUID requestId);

    @Modifying
    @Query("DELETE FROM PurchaseRequestItem i WHERE i.requestId = :rid")
    void deleteByRequestId(@Param("rid") UUID requestId);
}
