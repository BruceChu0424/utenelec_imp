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
 * <p>审核（status 0→1）触发：库存入库（stock_movements/balances）+ 回写订货明细 received_qty + 结案重算。
 * 红冲（1→-1）反向冲销。明细 {@link PurchaseReceiptItem} 独立仓库管理（不走 @OneToMany，规避软删+cascade 坑）。
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

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

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
