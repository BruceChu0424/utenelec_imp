package com.uten.imp.features.stock.dto;

import java.util.List;
import java.util.UUID;

/** Frozen per-document result of one atomic finished-in full-acceptance batch. */
public record FinishedInboundBatchConfirmResponse(
        UUID batchId,
        boolean replay,
        int confirmedCount,
        List<Item> items) {

    public FinishedInboundBatchConfirmResponse {
        items = items == null ? List.of() : List.copyOf(items);
    }

    public record Item(
            UUID documentId,
            String billNo,
            short status) {
    }
}
