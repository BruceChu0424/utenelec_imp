package com.uten.imp.features.production.fulfillment;

import com.uten.imp.common.domain.SoftDeletableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * Finished-product execution partition for one source production-plan item.
 *
 * <p>This is deliberately independent from {@code production_plans} and
 * {@code subplan_links}; those tables continue to model real make/subassembly
 * plans, not workshop execution slices of a finished product.
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "production_execution_segments")
public class ProductionExecutionSegment extends SoftDeletableEntity {

    public static final String STATUS_READY = "READY";
    public static final String STATUS_WAITING = "WAITING";
    public static final String STATUS_DISPATCHED = "DISPATCHED";
    public static final String STATUS_IN_PROGRESS = "IN_PROGRESS";
    public static final String STATUS_COMPLETED = "COMPLETED";
    public static final String STATUS_CANCELLED = "CANCELLED";
    public static final String STATUS_REVERSED = "REVERSED";

    @Column(name = "package_id", nullable = false)
    private UUID packageId;

    @Column(name = "plan_id", nullable = false)
    private UUID planId;

    @Column(name = "source_plan_item_id", nullable = false)
    private UUID sourcePlanItemId;

    @Column(name = "segment_no", nullable = false)
    private Integer segmentNo;

    @Column(name = "segment_code", nullable = false)
    private String segmentCode;

    @Column(name = "client_segment_key", nullable = false)
    private String clientSegmentKey;

    @Column(name = "product_goods_id", nullable = false)
    private UUID productGoodsId;

    @Column(name = "product_color_id")
    private UUID productColorId;

    @Column(name = "product_unit_id", nullable = false)
    private UUID productUnitId;

    @Column(name = "product_unit_rate", nullable = false, precision = 18, scale = 6)
    private BigDecimal productUnitRate;

    @Column(name = "planned_qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal plannedQty;

    @Column(nullable = false)
    private String status;

    @Column(name = "workshop_department_id")
    private UUID workshopDepartmentId;

    @Column(name = "team_department_id")
    private UUID teamDepartmentId;

    @Column(name = "responsible_employee_id")
    private UUID responsibleEmployeeId;

    @Column(name = "plan_begin_date")
    private LocalDate planBeginDate;

    @Column(name = "plan_end_date")
    private LocalDate planEndDate;

    @Column(name = "bom_fingerprint", nullable = false)
    private String bomFingerprint;

    @Column(name = "idempotency_key", nullable = false)
    private String idempotencyKey;

    @Column(name = "completion_reopened", nullable = false)
    private boolean completionReopened;

    @Column(name = "lock_version", nullable = false)
    private Long lockVersion = 0L;
}
