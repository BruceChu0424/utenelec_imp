package com.uten.imp.features.production.mrp;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

import java.time.Instant;
import java.util.UUID;

/** Non-authoritative pre-approval planning proposal. */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "production_planning_drafts")
public class ProductionPlanningDraft {

    public static final String STATUS_ACTIVE = "ACTIVE";
    public static final String STATUS_APPLIED = "APPLIED";
    public static final String STATUS_SUPERSEDED = "SUPERSEDED";

    @Id
    @Column(nullable = false, updatable = false)
    private UUID id = UUID.randomUUID();

    @Column(name = "plan_id", nullable = false, updatable = false)
    private UUID planId;

    @Column(name = "warehouse_id", nullable = false, updatable = false)
    private UUID warehouseId;

    @Column(nullable = false)
    private String status = STATUS_ACTIVE;

    @Column(name = "payload_version", nullable = false, updatable = false)
    private short payloadVersion = 1;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(nullable = false, columnDefinition = "jsonb", updatable = false)
    private JsonNode payload;

    @Column(name = "request_hash", nullable = false, updatable = false)
    private String requestHash;

    @Column(name = "preview_fingerprint", nullable = false, updatable = false)
    private String previewFingerprint;

    @Column(name = "planned_by", nullable = false, updatable = false)
    private UUID plannedBy;

    @Column(name = "planned_at", nullable = false, updatable = false)
    private Instant plannedAt = Instant.now();

    @Column(name = "resolved_by")
    private UUID resolvedBy;

    @Column(name = "resolved_at")
    private Instant resolvedAt;

    @Column(name = "resolution_reason")
    private String resolutionReason;

    @Column(name = "applied_package_id")
    private UUID appliedPackageId;
}
