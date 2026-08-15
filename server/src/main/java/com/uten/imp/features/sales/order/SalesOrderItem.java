package com.uten.imp.features.sales.order;

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

/**
 * 销售订货明细。源 S_OrderItem。
 *
 * <p>shipped_qty 出货审核回写 / returned_qty 退货审核回写 / flag_qty 人工维护（结案扣减项）。
 * 丢弃老库 IQTY/PQTY/LQTY/POQTY/PIQTY/PWQTY 跨模块累计量（按需从下游聚合）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "sales_order_items")
public class SalesOrderItem extends BaseEntity {

    private Integer legacyId;

    @Column(name = "bill_no")
    private String billNo;

    @Column(name = "bill_date")
    private LocalDate billDate;

    @Column(name = "order_id", nullable = false)
    private UUID orderId;

    private Integer lineNo;

    @Column(name = "goods_id", nullable = false)
    private UUID goodsId;

    @Column(name = "goods_code_snapshot")
    private String goodsCodeSnapshot;

    @Column(name = "goods_name_snapshot")
    private String goodsNameSnapshot;

    @Column(name = "goods_snapshot_source", nullable = false)
    private String goodsSnapshotSource;

    @Column(name = "goods_snapshot_locked_at")
    private java.time.OffsetDateTime goodsSnapshotLockedAt;

    @Column(name = "color_id")
    private UUID colorId;

    @Column(name = "unit_id")
    private UUID unitId;

    @Column(name = "unit_rate", precision = 18, scale = 6)
    private BigDecimal unitRate;

    @Column(name = "qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal qty;

    @Column(name = "price", precision = 18, scale = 4)
    private BigDecimal price;

    @Column(name = "amount_original", precision = 18, scale = 4)
    private BigDecimal amountOriginal;

    @Column(name = "amount_local", precision = 18, scale = 4)
    private BigDecimal amountLocal;

    /** 已发量（出货审核回写）。 */
    @Column(name = "shipped_qty", precision = 18, scale = 4)
    private BigDecimal shippedQty = BigDecimal.ZERO;

    /** 已退量（退货审核回写）。 */
    @Column(name = "returned_qty", precision = 18, scale = 4)
    private BigDecimal returnedQty = BigDecimal.ZERO;

    /** 标记不交付量（结案扣减项，人工维护）。 */
    @Column(name = "flag_qty", precision = 18, scale = 4)
    private BigDecimal flagQty = BigDecimal.ZERO;

    @Column(name = "discount", precision = 18, scale = 4)
    private BigDecimal discount = BigDecimal.ZERO;

    @Column(name = "tax_amount", precision = 18, scale = 4)
    private BigDecimal taxAmount = BigDecimal.ZERO;

    @Column(name = "weight", precision = 18, scale = 4)
    private BigDecimal weight;

    @Column(name = "client_no")
    private String clientNo;

    @Column(name = "client_model")
    private String clientModel;

    @Column(name = "deliver_date")
    private LocalDate deliverDate;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    /** JPrice 机加价（补列，销售报表用）。 */
    @Column(name = "machining_price", precision = 18, scale = 4)
    private BigDecimal machiningPrice;

    /** KQTY2 围数（补列，包装派生）。 */
    @Column(name = "circumference", precision = 18, scale = 4)
    private BigDecimal circumference;

    /** IQTY 进仓数量（补列，仓库回写历史累计；新库不再回写）。 */
    @Column(name = "inbound_qty", precision = 18, scale = 4)
    private BigDecimal inboundQty = BigDecimal.ZERO;

    /** InNo 成品进仓单号（补列，分列展示）。 */
    @Column(name = "in_no")
    private String inNo;

    /** OutNo 销售出货单号（补列，分列展示）。 */
    @Column(name = "out_no")
    private String outNo;

    /** 当前生效预留量（行单位）：可发货量；现货审核预留+生产入库补预留，出货/取消/驳回扣减。 */
    @Column(name = "reserved_qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal reservedQty = BigDecimal.ZERO;

    /** 已排产量（行单位）：plan_order_item_links 聚合回写。 */
    @Column(name = "planned_qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal plannedQty = BigDecimal.ZERO;

    /** 累计完工入库量（行单位）：生产入库审核回写（含补产）。 */
    @Column(name = "produced_qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal producedQty = BigDecimal.ZERO;

    /** 链路行状态（Service 派生）：0未启动/1部分预留/2待排产/3待物料/4已排产/5生产中/6部分完工/7可发货/8部分发货/9已发货/-1已取消。 */
    @Column(name = "chain_status", nullable = false)
    private Short chainStatus = 0;

    /**
     * 订单行优先级（稀缺重排用）：1急单 / 2普通 / 3现货(默认)。
     * 急单需 sales_order:priority 权限 + 原因 + 审计；让单时低优先级行预留可被释放回退待排产。
     */
    @Column(name = "priority", nullable = false)
    private Short priority = 3;

    private String remark;
}
