package com.uten.imp.features.production.fulfillment;

import com.uten.imp.common.domain.SoftDeletableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.UUID;

/** Idempotent, atomic confirmation boundary for one production plan. */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "production_planning_packages")
public class ProductionPlanningPackage extends SoftDeletableEntity {

    public static final String STATUS_CONFIRMED = "CONFIRMED";
    public static final String STATUS_CANCELLED = "CANCELLED";
    public static final String STATUS_REVERSED = "REVERSED";

    @Column(name = "plan_id", nullable = false)
    private UUID planId;

    @Column(name = "warehouse_id", nullable = false)
    private UUID warehouseId;

    @Column(name = "idempotency_key", nullable = false)
    private String idempotencyKey;

    @Column(name = "request_hash", nullable = false)
    private String requestHash;

    @Column(name = "preview_fingerprint", nullable = false)
    private String previewFingerprint;

    @Column(name = "execution_model_version", nullable = false)
    private Short executionModelVersion = 0;

    @Column(nullable = false)
    private String status = STATUS_CONFIRMED;

    @Column(name = "purchase_request_id")
    private UUID purchaseRequestId;

    @Column(name = "cancel_idempotency_key")
    private String cancelIdempotencyKey;

    @Column(name = "reverse_idempotency_key")
    private String reverseIdempotencyKey;

    @Column(name = "lifecycle_reason")
    private String lifecycleReason;

    @Column(name = "lock_version", nullable = false)
    private Long lockVersion = 0L;
}
