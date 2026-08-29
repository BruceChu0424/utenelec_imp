package com.uten.imp.features.production.dailyreport;

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
 * 生产日报明细（生产管理 · 源 F_DateReportItem，<b>0 行 · 空结构保未来</b>）。
 *
 * <p>同 {@link ProductionDailyReport}：老库从未启用，本期建空结构（design §3.4）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "production_daily_report_items")
public class ProductionDailyReportItem extends BaseEntity {

    private Integer legacyId;

    @Column(name = "bill_no")
    private String billNo;

    @Column(name = "bill_date")
    private LocalDate billDate;

    @Column(name = "report_id", nullable = false)
    private UUID reportId;

    private Integer lineNo;

    @Column(name = "goods_id", nullable = false)
    private UUID goodsId;

    @Column(name = "color_id")
    private UUID colorId;

    @Column(name = "unit_id")
    private UUID unitId;

    @Column(name = "unit_rate", precision = 18, scale = 6)
    private BigDecimal unitRate;

    /** 完工量（float→numeric）。 */
    @Column(name = "qty", precision = 18, scale = 4)
    private BigDecimal qty;

    @Column(name = "price", precision = 18, scale = 4)
    private BigDecimal price;

    /** 金额。 */
    @Column(name = "total", precision = 18, scale = 4)
    private BigDecimal total;

    /** 成本金额。 */
    @Column(name = "stotal", precision = 18, scale = 4)
    private BigDecimal stotal;

    /** OrderID → sales_order_items.id（跨模块不建 FK）。 */
    @Column(name = "sales_order_item_id")
    private UUID salesOrderItemId;

    @Column(name = "sales_order_no")
    private String salesOrderNo;

    /** PlanID → production_plan_items.id（同表内引用，不建 FK 避复杂）。 */
    @Column(name = "plan_item_id")
    private UUID planItemId;

    /** Exact execution segment; nullable only for legacy plans. */
    @Column(name = "execution_segment_id")
    private UUID executionSegmentId;

    /** Exact segment-to-sales-order allocation. */
    @Column(name = "execution_segment_sales_allocation_id")
    private UUID executionSegmentSalesAllocationId;

    /** Exact append-only FQC remediation lot consumed by this replacement attempt. */
    @Column(name = "fqc_recovery_authorization_id")
    private UUID fqcRecoveryAuthorizationId;

    /** 报工完结标记：该计划行不再继续报工；合格不足触发缺额封顶 + 自动补产。 */
    @Column(name = "is_final", nullable = false)
    private boolean isFinal = false;

    @Column(name = "plan_no")
    private String planNo;

    /** OutNo 发货单号。 */
    @Column(name = "outbound_no")
    private String outboundNo;

    /** OutQTY 发货量。 */
    @Column(name = "outbound_qty", precision = 18, scale = 4)
    private BigDecimal outboundQty;

    /** OrderQTY 订货量。 */
    @Column(name = "order_qty", precision = 18, scale = 4)
    private BigDecimal orderQty;

    /** StepID → B_Step（主档未建）。 */
    @Column(name = "step_legacy_id")
    private Integer stepLegacyId;

    /** OrderDate 下订日期。 */
    @Column(name = "order_date")
    private LocalDate orderDate;

    /** Boxs 箱数。 */
    @Column(name = "boxes", precision = 18, scale = 4)
    private BigDecimal boxes;

    /** KQTY 把/箱。 */
    @Column(name = "per_box_qty", precision = 18, scale = 4)
    private BigDecimal perBoxQty;

    @Column(name = "weight", precision = 18, scale = 4)
    private BigDecimal weight;

    /** Client 客户名冗余。 */
    @Column(name = "client_name")
    private String clientName;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    private String remark;
}
