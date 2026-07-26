package com.uten.imp.features.subcontract.receipt;

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
 * 委外进仓单主表（委外管理）。源 E_In（收回成品）。
 *
 * <p>审核（status 0→1）触发（同事务）：
 * <ol>
 *   <li>库存入库 {@code TYPE_SUBCONTRACT_RECEIPT=17} {@code DIR_IN=+1}（正向入库；<b>不照搬老库 QTY-= 反向</b>）</li>
 *   <li>回写订货明细 {@code received_qty += qty}</li>
 *   <li>{@code ArApLedgerService.postArAp(AP, SUBCONTRACT_RECEIPT, +amount)} 立应付</li>
 *   <li>置 {@code ap_posted=true}；重算订货单 is_closed</li>
 * </ol>
 * 红冲（1→-1）：先 {@code reverseArAp}，再反向 DIR_OUT、回减 received_qty、重算 is_closed。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "subcontract_receipts")
public class SubcontractReceipt extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;            // E_In.ID

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    @Column(name = "supplier_id")
    private UUID supplierId;             // VendID（委外商，AP 落此）

    @Column(name = "warehouse_id")
    private UUID warehouseId;            // StockID（入库仓，必填）

    @Column(name = "currency_id")
    private UUID currencyId;

    @Column(name = "exchange_rate", precision = 18, scale = 6)
    private BigDecimal exchangeRate;

    @Column(name = "tax_rate", precision = 18, scale = 4)
    private BigDecimal taxRate;

    @Column(name = "sender_id")
    private UUID senderId;               // 交货人（无 FK，常空）

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

    @Column(name = "last_date")
    private LocalDate lastDate;

    /** 应付已立帐标志（审核→postArAp 后置 true；红冲 reverseArAp 后置 false）。契约 28 §四。 */
    @Column(name = "ap_posted", nullable = false)
    private boolean apPosted = false;

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
