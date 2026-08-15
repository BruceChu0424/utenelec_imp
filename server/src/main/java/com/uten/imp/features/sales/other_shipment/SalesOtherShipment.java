package com.uten.imp.features.sales.other_shipment;

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
 * 其它出货单主表（销售管理）。源 S_OtherOut（不挂订单、不立应收）。
 *
 * <p>审核（status 0→1）：**仅**库存出库（type=20/dir=-1）；不回写订单、不立应收
 * （尊重老库触发器 TRI_OCStockItem 对应段已注释的语义，design 20 §〇/§4.1）。
 * 无 ar_posted 列。client_id 可空（内部领用场景）；out_type 用途枚举（样品/赠品/内部领用/损耗…）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "sales_other_shipments")
public class SalesOtherShipment extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    /** 可空：内部领用无客户。 */
    @Column(name = "client_id")
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

    @Column(name = "settlement_method_id")
    private UUID settlementMethodId;

    @Column(name = "seller_id")
    private UUID sellerId;
    /** 归属业务员（每个销售只看自己的单据；NULL=公共）。 */
    @Column(name = "owner_employee_id")
    private java.util.UUID ownerEmployeeId;

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

    @Column(name = "last_date")
    private OffsetDateTime lastDate;

    /** 用途：样品/赠品/内部领用/损耗…（前端枚举，新库增）。 */
    @Column(name = "out_type")
    private String outType;

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

    /** Optional source order UUID truth; sourceDocNo is only a snapshot. */
    @Column(name = "source_order_id")
    private UUID sourceOrderId;
}
