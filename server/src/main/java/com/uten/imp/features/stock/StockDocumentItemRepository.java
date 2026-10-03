package com.uten.imp.features.stock;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface StockDocumentItemRepository extends JpaRepository<StockDocumentItem, UUID> {

    @Query("SELECT i FROM StockDocumentItem i "
            + "WHERE i.docId = :did AND i.deleted = false "
            + "ORDER BY i.lineNo ASC")
    List<StockDocumentItem> findByDocIdOrderByLineNoAsc(
            @Param("did") UUID docId);

    /** Deleted headers can still show their last physical source rows, including exact soft-retired identities. */
    @Query("SELECT i FROM StockDocumentItem i WHERE i.docId = :did ORDER BY i.lineNo ASC, i.id ASC")
    List<StockDocumentItem> findHistoryByDocIdOrderByLineNoAsc(@Param("did") UUID docId);

    @Modifying
    @Query("DELETE FROM StockDocumentItem i WHERE i.docId = :did")
    void deleteByDocId(@Param("did") UUID docId);
}
