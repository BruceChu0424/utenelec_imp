package com.uten.imp.features.subcontract.ret;

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
 * 委外退货单主表（委外管理，<b>包名 ret 避开 Java 关键字 return</b>）。源 E_WithDraw（成品退）。
 *
 * <p>审核（status 0→1）触发（同事务）：
 * <ol>
 *   <li>库存出库 {@code TYPE_SUBCONTRACT_RETURN=18} {@code DIR_OUT=-1}</li>
 *   <li>双回写：{@code receipt_items.returned_qty += qty} + {@code order_items.returned_qty += qty}</li>
 *   <li>{@code ArApLedgerService.postArAp(AP, SUBCONTRACT_RETURN, -amount)} <b>反向立帐</b>
 *       （冲减进仓单立的应付；amount 传负值）</li>
 *   <li>置 {@code ap_posted=true}；重算订货单 is_closed</li>
 * </ol>
 * 红冲（1→-1）：先 {@code reverseArAp}，再反向 DIR_IN + 回减 returned_qty + 重算 is_closed。
 *
 * <p>注：AP 反向走 postArAp 负向（在新 source_doc_id 上立一条负应付），不调进仓单的 reverseArAp
 * （那是进仓单红冲专用；退货是独立单据，立独立反向 AP）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "subcontract_returns")
public class SubcontractReturn extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;            // E_WithDraw.ID

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    @Column(name = "supplier_id")
    private UUID supplierId;

    @Column(name = "warehouse_id")
    private UUID warehouseId;            // 必填（出库仓）

    @Column(name = "currency_id")
    private UUID currencyId;

    @Column(name = "exchange_rate", precision = 18, scale = 6)
    private BigDecimal exchangeRate;

    @Column(name = "tax_rate", precision = 18, scale = 4)
    private BigDecimal taxRate;

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

    @Column(name = "last_date")
    private LocalDate lastDate;

    /** 应付反向立帐标志（审核→postArAp 负向后置 true；红冲 reverseArAp 后置 false）。契约 28 §四。 */
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

    /** 老库结帐方式（E_WithDraw.PStyle → B_PStyle 字典 ID）。报表渲染成文字。 */
    @Column(name = "settlement_style_legacy")
    private Integer settlementStyleLegacy;

    @Column(name = "settlement_method_id")
    private UUID settlementMethodId;

    /** 制单员 legacy id（E_WithDraw.MakeID → Sys_Operator.ID）。 */
    @Column(name = "maker_legacy_id")
    private Integer makerLegacyId;

    /** 制单员名（迁移期冻结 Sys_Operator.fname）。 */
    @Column(name = "maker_name")
    private String makerName;

    /** 审核员 legacy id（E_WithDraw.ApproverID → Sys_Operator.ID）。 */
    @Column(name = "approver_legacy_id")
    private Integer approverLegacyId;

    /** 审核员名（迁移期冻结 Sys_Operator.fname）。 */
    @Column(name = "approver_name")
    private String approverName;
}
