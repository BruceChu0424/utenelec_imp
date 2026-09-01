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
 * 出入库流水（库存联动）。
 *
 * <p>所有单据（采购收货/退货、销售、领料、盘点、调拨…）统一入口；direction +1 入 / -1 出。
 * 流水只增不改、不软删（事件溯源语义）。表 stock_movements。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "stock_movements")
public class StockMovement extends BaseEntity {

    @Column(name = "transaction_date", nullable = false)
    private OffsetDateTime transactionDate;

    /** 1采购入库 2采购退货 3销售出库 4销售退货 5领料 6退料 7调拨入 8调拨出 9盘盈 10盘亏 11其它入 12其它出。 */
    @Column(name = "movement_type", nullable = false)
    private Short movementType;

    @Column(name = "source_doc_type", nullable = false)
    private String sourceDocType;          // PURCHASE_RECEIPT / PURCHASE_RETURN / ...

    @Column(name = "source_doc_id")
    private UUID sourceDocId;

    @Column(name = "source_item_id")
    private UUID sourceItemId;

    @Column(name = "goods_id", nullable = false)
    private UUID goodsId;

    @Column(name = "color_id")
    private UUID colorId;

    @Column(name = "warehouse_id", nullable = false)
    private UUID warehouseId;

    /** +1 入库 / -1 出库。 */
    @Column(name = "direction", nullable = false)
    private Short direction;

    /** 基本单位量（已乘 unit_rate）。 */
    @Column(name = "qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal qty;

    @Column(name = "unit_id")
    private UUID unitId;

    @Column(name = "unit_rate", precision = 18, scale = 6)
    private BigDecimal unitRate;

    @Column(name = "amount_local", precision = 18, scale = 4)
    private BigDecimal amountLocal;

    /** 本次流水切片的实际总重量；方向由 direction 表示，不乘 unit_rate。 */
    @Column(name = "weight", precision = 18, scale = 4)
    private BigDecimal weight;

    /** V442 explicit unit for the actual-weight snapshot; nullable for legacy/unitless sources. */
    @Column(name = "actual_weight_unit_id")
    private UUID actualWeightUnitId;

    private String remark;
}
