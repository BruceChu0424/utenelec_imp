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
 * 表 stock_balances（V45），唯一约束 (warehouse_id, goods_id, color_id) NULLS NOT DISTINCT。
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

    @Column(name = "amount_local", precision = 18, scale = 4)
    private BigDecimal amountLocal;

    @Column(name = "last_movement_date")
    private OffsetDateTime lastMovementDate;
}
