package com.uten.imp.features.stock;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface StockDocumentItemRepository extends JpaRepository<StockDocumentItem, UUID> {

    List<StockDocumentItem> findByDocIdOrderByLineNoAsc(UUID docId);

    @Modifying
    @Query("DELETE FROM StockDocumentItem i WHERE i.docId = :did")
    void deleteByDocId(@Param("did") UUID docId);
}
