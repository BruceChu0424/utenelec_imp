package com.uten.imp.features.stock.dto;

/** Physical document and revision fingerprint captured under the same document lock. */
public record StockDocOutboundReview(StockDocDetail document, String reviewToken) {
}
