package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.domain.SoftDeletableEntity;
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

/**
 * 销售出货单主表（销售管理）。源 S_Out（主流量）。
 *
 * <p>审核（status 0→1）：库存出库（type=3/dir=-1）+ 回写 sales_order_items.shipped_qty
 * + 立应收（AR, SALES_SHIPMENT, BStyle=3, 正应收）+ 结案重算。ar_posted 立帐标志。
 * 红冲（1→-1）：先 reverseArAp 校验无收款核销 → 反向库存 + 回减 shipped_qty。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "sales_shipments")
public class SalesShipment extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    @Column(name = "client_id", nullable = false)
    private UUID clientId;

    @Column(name = "warehouse_id")
    private UUID warehouseId;

    @Column(name = "currency_id")
    private UUID currencyId;

    @Column(name = "exchange_rate", precision = 18, scale = 6)
    private BigDecimal exchangeRate;

    @Column(name = "tax_rate", precision = 18, scale = 4)
    private BigDecimal taxRate;

    @Column(name = "payment_style_id")
    private Integer paymentStyleId;

    @Column(name = "seller_id")
    private UUID sellerId;

    @Column(name = "sender_id")
    private UUID senderId;

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

    @Column(name = "ship_addr")
    private String shipAddr;

    @Column(name = "link_phone")
    private String linkPhone;

    @Column(name = "parcel_count")
    private Integer parcelCount;

    @Column(name = "print_count")
    private Integer printCount = 0;

    /** 最后操作日（立应收/到期日用）。 */
    @Column(name = "last_date")
    private OffsetDateTime lastDate;

    private String remark;

    @Column(name = "total_original", precision = 18, scale = 4)
    private BigDecimal totalOriginal;

    @Column(name = "total_local", precision = 18, scale = 4)
    private BigDecimal totalLocal;

    /** 0 草稿 / 1 已审 / -1 红冲。 */
    @Column(name = "status", nullable = false)
    private Short status = 0;

    @Column(name = "is_closed", nullable = false)
    private boolean closed = false;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    /** 应收已立帐标志（审核置 true，反审校验）。 */
    @Column(name = "ar_posted", nullable = false)
    private boolean arPosted = false;
}
