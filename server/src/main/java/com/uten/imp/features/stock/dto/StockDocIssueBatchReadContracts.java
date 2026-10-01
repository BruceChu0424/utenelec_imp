package com.uten.imp.features.stock.dto;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/** Read-only confirmation and result recovery for the ordinary atomic DRAW batch. */
public final class StockDocIssueBatchReadContracts {
    private StockDocIssueBatchReadContracts() {}

    public record Review(int protocolVersion, List<ReviewedDocument> documents) {
        public Review { documents = List.copyOf(documents); }
    }
    public record ReviewedDocument(UUID docId, String billNo, String reviewToken, List<ReviewedItem> items) {
        public ReviewedDocument { items = List.copyOf(items); }
    }
    public record ReviewedItem(UUID itemId, BigDecimal requestedQty, BigDecimal issuedQty) {}

    /** UNKNOWN includes uncommitted/in-flight requests; it never asserts that a command failed. */
    public record Resolution(String state, String idempotencyKey, String requestHash,
                             List<UUID> docIds, StockDocIssueBatchResponse result) {
        public Resolution { docIds = List.copyOf(docIds); }
    }
}
