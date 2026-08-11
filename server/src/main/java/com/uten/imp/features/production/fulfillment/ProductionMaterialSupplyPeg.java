package com.uten.imp.features.production.fulfillment;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** Explicit demand-to-purchase/subcontract source allocation. */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "production_material_supply_pegs")
public class ProductionMaterialSupplyPeg extends BaseEntity {

    public static final String STATUS_EFFECTIVE = "EFFECTIVE";
    public static final String STATUS_DONE = "DONE";
    public static final String STATUS_RELEASED = "RELEASED";
    public static final String STATUS_REVERSED = "REVERSED";

    @Column(name = "demand_id", nullable = false)
    private UUID demandId;

    @Column(name = "supply_type", nullable = false)
    private String supplyType;

    @Column(name = "supply_item_id", nullable = false)
    private UUID supplyItemId;

    @Column(name = "allocated_qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal allocatedQty;

    @Column(name = "consumed_qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal consumedQty = BigDecimal.ZERO;

    @Column(name = "released_qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal releasedQty = BigDecimal.ZERO;

    @Column(name = "expected_date")
    private LocalDate expectedDate;

    @Column(nullable = false)
    private String status = STATUS_EFFECTIVE;

    @Column(name = "idempotency_key", nullable = false)
    private String idempotencyKey;

    @Column(name = "lock_version", nullable = false)
    private Long lockVersion = 0L;
}
