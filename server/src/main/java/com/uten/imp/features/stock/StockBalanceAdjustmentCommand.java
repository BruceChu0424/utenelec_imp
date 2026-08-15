package com.uten.imp.features.stock;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.UUID;

/**
 * Idempotent privileged stock-balance adjustment command.
 *
 * <p>The command UUID is the stable identity and {@code stockDocumentId} is
 * the authoritative relation. {@code requestKey} is only an opaque retry key;
 * it is never interpreted as a document number or authorization marker.
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "stock_balance_adjustment_requests")
public class StockBalanceAdjustmentCommand extends BaseEntity {

    @Column(name = "request_key", nullable = false, updatable = false)
    private String requestKey;

    @Column(name = "stock_document_id", nullable = false, updatable = false)
    private UUID stockDocumentId;
}
