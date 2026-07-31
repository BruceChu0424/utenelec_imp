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

/** Authoritative production material demand in base units. */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "production_material_demands")
public class ProductionMaterialDemand extends SoftDeletableEntity {

    public static final String STATUS_OPEN = "OPEN";
    public static final String STATUS_PARTIAL = "PARTIAL";
    public static final String STATUS_ALLOCATED = "ALLOCATED";
    public static final String STATUS_WAITING_SUPPLY = "WAITING_SUPPLY";
    public static final String STATUS_FULFILLED = "FULFILLED";
    public static final String STATUS_RELEASED = "RELEASED";
    public static final String STATUS_REVERSED = "REVERSED";

    public static final String ROUTE_BUY = "BUY";
    public static final String ROUTE_MAKE = "MAKE";
    public static final String ROUTE_SUBCONTRACT = "SUBCONTRACT";

    @Column(name = "package_id", nullable = false)
    private UUID packageId;

    @Column(name = "plan_id", nullable = false)
    private UUID planId;

    @Column(name = "execution_segment_id")
    private UUID executionSegmentId;

    @Column(name = "source_plan_item_id")
    private UUID sourcePlanItemId;

    @Column(name = "warehouse_id", nullable = false)
    private UUID warehouseId;

    @Column(name = "goods_id", nullable = false)
    private UUID goodsId;

    @Column(name = "color_id")
    private UUID colorId;

    @Column(name = "unit_id", nullable = false)
    private UUID unitId;

    @Column(name = "required_qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal requiredQty;

    @Column(name = "per_product_qty", precision = 18, scale = 6)
    private BigDecimal perProductQty;

    @Column(name = "released_qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal releasedQty = BigDecimal.ZERO;

    @Column(name = "need_date")
    private LocalDate needDate;

    @Column(name = "supply_route", nullable = false)
    private String supplyRoute;

    @Column(nullable = false)
    private String status = STATUS_OPEN;

    @Column(name = "idempotency_key", nullable = false)
    private String idempotencyKey;

    @Column(name = "lock_version", nullable = false)
    private Long lockVersion = 0L;
}
