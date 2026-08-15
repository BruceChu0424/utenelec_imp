package com.uten.imp.features.purchase.order;

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
 * 采购订货单主表（采购管理）。源 P_Order。
 *
 * <p>审核（status 0→1）：回写申请明细 ordered_qty + 重算申请单 is_closed（订货不入库，不碰库存）。
 * 被收货/退货单回写 received_qty/returned_qty + is_closed。源 P_Order 无仓库字段（warehouseId 留空）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "purchase_orders")
public class PurchaseOrder extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    @Column(name = "supplier_id")
    private UUID supplierId;

    @Column(name = "warehouse_id")
    private UUID warehouseId;

    @Column(name = "currency_id")
    private UUID currencyId;

    @Column(name = "exchange_rate", precision = 18, scale = 6)
    private BigDecimal exchangeRate;

    @Column(name = "tax_rate", precision = 18, scale = 4)
    private BigDecimal taxRate;

    @Column(name = "purchaser_id")
    private UUID purchaserId;

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

    @Column(name = "purchaser_legacy_id")
    private Integer purchaserLegacyId;

    @Column(name = "maker_legacy_id")
    private Integer makerLegacyId;

    @Column(name = "approver_legacy_id")
    private Integer approverLegacyId;

    @Column(name = "deliver_date")
    private LocalDate deliverDate;

    private String remark;

    @Column(name = "total_original", precision = 18, scale = 4)
    private BigDecimal totalOriginal;

    @Column(name = "total_local", precision = 18, scale = 4)
    private BigDecimal totalLocal;

    @Column(name = "status", nullable = false)
    private Short status = 0;

    @Column(name = "is_closed", nullable = false)
    private boolean closed = false;

    /** 老库 PStyle（结帐方式原值，无字典，前端按字典常量渲染）。 */
    @Column(name = "settlement_style_legacy")
    private Short settlementStyleLegacy;

    @Column(name = "settlement_method_id")
    private UUID settlementMethodId;

    /** 老库 Stop 位（是否中止）。默认 FALSE，用 Boolean 包装以兼容历史 NULL。 */
    @Column(name = "is_stopped")
    private Boolean isStopped = false;

    @Column(name = "source_doc_no")
    private String sourceDocNo;
}
