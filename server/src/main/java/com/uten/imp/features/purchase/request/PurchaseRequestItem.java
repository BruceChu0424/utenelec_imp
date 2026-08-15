package com.uten.imp.features.purchase.request;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

/** 采购申请明细。源 P_ApplicationItem。ordered_qty 由订货单审核回写。 */
@Getter @Setter @NoArgsConstructor @Entity @Table(name = "purchase_request_items")
public class PurchaseRequestItem extends BaseEntity {
    private Integer legacyId;
    @Column(name = "bill_no") private String billNo;
    @Column(name = "bill_date") private LocalDate billDate;
    @Column(name = "request_id", nullable = false) private UUID requestId;
    private Integer lineNo;
    @Column(name = "goods_id", nullable = false) private UUID goodsId;
    @Column(name = "goods_code_snapshot") private String goodsCodeSnapshot;
    @Column(name = "goods_name_snapshot") private String goodsNameSnapshot;
    @Column(name = "goods_snapshot_source", nullable = false) private String goodsSnapshotSource;
    @Column(name = "goods_snapshot_locked_at") private OffsetDateTime goodsSnapshotLockedAt;
    @Column(name = "color_id") private UUID colorId;
    @Column(name = "unit_id") private UUID unitId;
    @Column(name = "unit_rate", precision = 18, scale = 6) private BigDecimal unitRate;
    @Column(name = "qty", nullable = false, precision = 18, scale = 4) private BigDecimal qty;
    @Column(name = "price", precision = 18, scale = 4) private BigDecimal price;
    @Column(name = "amount_original", precision = 18, scale = 4) private BigDecimal amountOriginal;
    @Column(name = "amount_local", precision = 18, scale = 4) private BigDecimal amountLocal;
    /** 已订量（订货单审核回写）。 */
    @Column(name = "ordered_qty", precision = 18, scale = 4) private BigDecimal orderedQty = BigDecimal.ZERO;
    @Column(name = "gift_qty", precision = 18, scale = 4) private BigDecimal giftQty = BigDecimal.ZERO;
    @Column(name = "weight", precision = 18, scale = 4) private BigDecimal weight;
    @Column(name = "source_doc_no") private String sourceDocNo;
    /** 老库交叉引用文本（软关联，报表按列展示，不强 FK）。 */
    @Column(name = "deliver_date") private LocalDate deliverDate;
    @Column(name = "production_no") private String productionNo;
    @Column(name = "purchase_order_no") private String purchaseOrderNo;
    @Column(name = "sales_order_no") private String salesOrderNo;
    @Column(name = "production_plan_no") private String productionPlanNo;
    @Column(name = "purchase_reply") private String purchaseReply;
    @Column(name = "summary") private String summary;
    private String remark;
}
