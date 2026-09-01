package com.uten.imp.features.purchase.receipt;

import com.uten.imp.common.domain.SoftDeletableEntity;
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
 * 采购收货单主表（采购管理）。源 P_In。
 *
 * <p>审核（status 0→1）只登记 IQC 待检隔离、回写实到量并形成采购 AP；不写可用库存。
 * IQC PASS 只形成合格待入库切片并以品质净量重算订货结案；
 * 仓库确认后才写可用库存，FAIL 永不入库存。
 * 红冲（1→-1）须先满足质检/付款/抵销反向守卫。明细 {@link PurchaseReceiptItem}
 * 独立仓库管理（不走 @OneToMany，规避软删+cascade 坑）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "purchase_receipts")
public class PurchaseReceipt extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;          // P_In.ID

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    @Column(name = "supplier_id")
    private UUID supplierId;           // VendID（收货必填，审核校验）

    @Column(name = "warehouse_id")
    private UUID warehouseId;          // StockID（收货必填，库存记账维度）

    @Column(name = "currency_id")
    private UUID currencyId;

    @Column(name = "exchange_rate", precision = 18, scale = 6)
    private BigDecimal exchangeRate;

    @Column(name = "tax_rate", precision = 18, scale = 4)
    private BigDecimal taxRate;

    @Column(name = "sender_id")
    private UUID senderId;             // 交货人（无 FK）

    @Column(name = "receiver_id")
    private UUID receiverId;           // 收货人（无 FK）

    /** 采购员 UUID 真源（老库 purchaser_legacy_id 仅作兼容快照）。 */
    @Column(name = "purchaser_id")
    private UUID purchaserId;

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

    @Column(name = "sender_legacy_id")
    private Integer senderLegacyId;    // 老库 B_Worker.ID（待 employees.legacy_id 对齐）

    @Column(name = "receiver_legacy_id")
    private Integer receiverLegacyId;

    @Column(name = "maker_legacy_id")
    private Integer makerLegacyId;

    @Column(name = "approver_legacy_id")
    private Integer approverLegacyId;

    @Column(name = "purchaser_legacy_id")
    private Integer purchaserLegacyId;

    /** 老库 PStyle（结帐方式原值，无字典，前端按字典常量渲染）。 */
    @Column(name = "settlement_style_legacy")
    private Short settlementStyleLegacy;

    @Column(name = "settlement_method_id")
    private UUID settlementMethodId;

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
}
