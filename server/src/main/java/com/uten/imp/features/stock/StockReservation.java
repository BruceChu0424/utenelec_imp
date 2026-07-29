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
 * 库存软预留台账（业务链核心，V90）。
 *
 * <p>可用库存 = stock_balances.qty − Σ生效预留(qty − consumed_qty − released_qty)，
 * 统一口径视图 v_stock_available。生命周期由 Service 对称维护：
 * 订货审核建行 / 出货审核消耗 / 改量·取消·驳回释放。
 *
 * <p>数量一律基本单位（创建时 行量×unit_rate 换算），与 stock_balances.qty 同口径直接相减。
 * warehouse_id NULL = 全局预留（下单时未定出货仓，占全局可用量；出货开单后改绑具体仓）。
 * order_item_id → sales_order_items.id 为跨模块逻辑 FK（契约 §一，不建 REFERENCES）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "stock_reservations")
public class StockReservation extends BaseEntity {

    public static final short STATUS_EFFECTIVE = 0;
    public static final short STATUS_DONE = 1;

    public static final short SOURCE_ORDER = 0;             // 下单现货预留
    public static final short SOURCE_PRODUCTION_IN = 1;     // 生产入库预留

    /** → sales_order_items.id（跨模块逻辑 FK）。 */
    @Column(name = "order_item_id", nullable = false)
    private UUID orderItemId;

    @Column(name = "goods_id", nullable = false)
    private UUID goodsId;

    @Column(name = "color_id")
    private UUID colorId;

    /** NULL = 全局预留。 */
    @Column(name = "warehouse_id")
    private UUID warehouseId;

    /** 预留量（基本单位）。 */
    @Column(name = "qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal qty;

    /** 已转出库消耗（出货审核回写）。 */
    @Column(name = "consumed_qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal consumedQty = BigDecimal.ZERO;

    /** 已释放（改量/取消/驳回回写）。 */
    @Column(name = "released_qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal releasedQty = BigDecimal.ZERO;

    /** 0生效 / 1已完结（Service 派生）。 */
    @Column(name = "status", nullable = false)
    private Short status = STATUS_EFFECTIVE;

    /** 0下单现货 / 1生产入库。 */
    @Column(name = "source", nullable = false)
    private Short source = SOURCE_ORDER;

    /** 产生预留的单据类型：SALES_ORDER / PRODUCTION_INBOUND。 */
    @Column(name = "source_doc_type")
    private String sourceDocType;

    @Column(name = "source_doc_id")
    private UUID sourceDocId;

    @Column(name = "is_deleted", nullable = false)
    private boolean deleted = false;

    @Column(name = "deleted_at")
    private OffsetDateTime deletedAt;

    /** 当前生效量 = qty − consumed − released。 */
    public BigDecimal effectiveQty() {
        return qty.subtract(consumedQty).subtract(releasedQty);
    }
}
