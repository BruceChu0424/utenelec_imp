package com.uten.imp.features.stock;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 库存当前余额（仓库+货品+颜色 粒度）。
 *
 * <p>由 {@link StockService#recordMovement} 在出入库时 upsert 维护（同事务），对用户零割裂。
 * 表 stock_balances，唯一约束 (warehouse_id, goods_id, color_id) NULLS NOT DISTINCT。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "stock_balances")
public class StockBalance extends BaseEntity {

    @Column(name = "warehouse_id", nullable = false)
    private UUID warehouseId;

    @Column(name = "goods_id", nullable = false)
    private UUID goodsId;

    /** null = 无色货品。 */
    @Column(name = "color_id")
    private UUID colorId;

    /** 当前余量（基本单位）。 */
    @Column(name = "qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal qty;

    /** 本币金额（采购=入库成本）。 */
    @Column(name = "amount_local", precision = 18, scale = 4)
    private BigDecimal amountLocal;

    /**
     * 当前库存重量(千克), null = 未知; 数量为 0 时是 0, 数量大于 0 时大于 0。由库存账在锁下整值改写(ADR-135)。
     */
    @Column(name = "weight", precision = 18, scale = 4)
    private BigDecimal weight;

    /** 库存重量是否含估算(按均重/单重推算), 界面显示「≈」。 */
    @Column(name = "weight_estimated", nullable = false)
    private boolean weightEstimated;

    @Column(name = "last_movement_date")
    private OffsetDateTime lastMovementDate;
}
