package com.uten.imp.features.finance.arap;

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
 * 应收应付统一台账（钱流管理-应收应付）。合并老库 M_in(应收)+M_out(应付)。
 *
 * <p>跨模块立帐入口（销售/采购/委外 Service 调 {@link ArApLedgerService#postArAp}）。
 * direction 区分 AR/AP；source_doc_type 取代老库 BStyle int 字典。
 *
 * <p>核销关系：{@code finance_receipt_lines.applied_ledger_id} / {@code finance_payment_lines.applied_ledger_id}
 * 显式指向本表 id（取代老库 M_in.M_In 累加推断）。
 *
 * <p>余额等式：{@code amountBalance = amountOriginalLocal − amountSettled}（Service 维护）。
 * DIRECT_RECEIPT/DIRECT_PAYMENT 允许 balance 为负（客户/供应商预付款）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "ar_ap_ledger")
public class ArApLedger extends SoftDeletableEntity {

    /** AR 应收 / AP 应付。 */
    @Column(nullable = false)
    private String direction;

    /** 立帐来源单据类型枚举（见 V57 CHECK 约束 8 值）。 */
    @Column(name = "source_doc_type", nullable = false)
    private String sourceDocType;

    /** 来源单据 id（跨模块，不建 FK）。 */
    @Column(name = "source_doc_id")
    private UUID sourceDocId;

    /** 来源单号（跨模块查询用）。 */
    @Column(name = "source_doc_no")
    private String sourceDocNo;

    /** 立帐单号（XC/XT/CJ/CT/EJ/XS/CF 前缀，migration = source_doc_no）。 */
    @Column(name = "bill_no", nullable = false)
    private String billNo;

    /** 立帐日期。 */
    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    /** 到期日（源 Last_Date 收款/付款限期）。 */
    @Column(name = "due_date")
    private LocalDate dueDate;

    /** AR 对应客户（direction=AR 时填）。 */
    @Column(name = "client_id")
    private UUID clientId;

    /** AP 对应供应商（direction=AP 时填）。 */
    @Column(name = "supplier_id")
    private UUID supplierId;

    @Column(name = "currency_id")
    private UUID currencyId;

    @Column(name = "exchange_rate", precision = 18, scale = 6)
    private BigDecimal exchangeRate = BigDecimal.ONE;

    /** 原额（原币，多币种场景；默认 0 兼容单币种）。 */
    @Column(name = "amount_original", precision = 18, scale = 4)
    private BigDecimal amountOriginal = BigDecimal.ZERO;

    /** 原始金额（本币，退货为负；DIRECT_RECEIPT/PAYMENT 为 0）。 */
    @Column(name = "amount_original_local", nullable = true, precision = 18, scale = 4)
    private BigDecimal amountOriginalLocal = BigDecimal.ZERO;

    /** 已核销金额（累加，本币；收款/付款审核时 Service 回写）。 */
    @Column(name = "amount_settled", nullable = false, precision = 18, scale = 4)
    private BigDecimal amountSettled = BigDecimal.ZERO;

    /** 未核销余额 = original_local − settled（Service 维护；预付款可负）。 */
    @Column(name = "amount_balance", nullable = false, precision = 18, scale = 4)
    private BigDecimal amountBalance = BigDecimal.ZERO;

    /** 是否结清（balance ≤ 0 时 Service 置位，取代老库 TRI_GatheringCheck）。 */
    @Column(name = "is_settled", nullable = false)
    private boolean settled = false;

    /** 结清日期（源 PaidDate）。 */
    @Column(name = "settled_date")
    private LocalDate settledDate;

    /** PStyle 结算方式 id（老库 B_PStyle 字典未 dump，暂不 FK）。 */
    @Column(name = "settlement_type_id")
    private UUID settlementTypeId;

    /** 0 草稿 / 1 已审 / -1 红冲（跨模块立帐默认 1=已生效）。 */
    @Column(nullable = false)
    private Short status = 1;

    /** 老库溯源表名（M_in/M_out，解 ID 冲突）。 */
    @Column(name = "legacy_source")
    private String legacySource;

    /** 老库 M_in.ID 或 M_out.ID（按 legacy_source 区分）。 */
    @Column(name = "legacy_id")
    private Integer legacyId;

    /** 老库 BStyle int（3/18/20 应收侧，1/17/30/21 应付侧；保留校验）。 */
    @Column(name = "legacy_bstyle")
    private Short legacyBstyle;

    private String remark;
}
