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
 *   <li>登记 IQC 待检隔离；不写 {@code stock_balances}</li>
 *   <li>回写订货明细 {@code received_qty += qty}</li>
 *   <li>按财务批准加工费快照调用 {@code ArApLedgerService.postArAp(AP, SUBCONTRACT_RECEIPT, +amount)}</li>
 *   <li>置 {@code ap_posted=true}；订货结案继续等待 IQC 合格净量</li>
 * </ol>
 * IQC PASS 只形成仓库待入库量；仓库确认后才正向写可用库存，FAIL 不入库存。
 * 红冲先 {@code reverseArAp}，再精确反向仓库已确认
 * 库存、回减 received_qty 并重算结案。
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

    /** 老库结帐方式（E_In.PStyle → B_PStyle 字典 ID）。报表渲染成文字（现金/提货/...）。 */
    @Column(name = "settlement_style_legacy")
    private Integer settlementStyleLegacy;

    @Column(name = "settlement_method_id")
    private UUID settlementMethodId;

    /** 收货人 legacy id（E_In.SenderID → B_Worker.ID）。报表 LEFT JOIN employees 出名。 */
    @Column(name = "receiver_legacy_id")
    private Integer receiverLegacyId;

    /** 收货人名（历史冻结兜底；新单据走 receiver_id JOIN employees）。 */
    @Column(name = "receiver_name")
    private String receiverName;

    /** 制单员 legacy id（E_In.MakeID → Sys_Operator.ID）。 */
    @Column(name = "maker_legacy_id")
    private Integer makerLegacyId;

    /** 制单员名（迁移期冻结 Sys_Operator.fname）。 */
    @Column(name = "maker_name")
    private String makerName;

    /** 审核员 legacy id（E_In.ApproverID → Sys_Operator.ID）。 */
    @Column(name = "approver_legacy_id")
    private Integer approverLegacyId;

    /** 审核员名（迁移期冻结 Sys_Operator.fname）。 */
    @Column(name = "approver_name")
    private String approverName;
}
