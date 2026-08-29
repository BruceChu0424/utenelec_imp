package com.uten.imp.features.finance.reconciliation;

import com.uten.imp.common.domain.SoftDeletableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 账户统一流水帐（钱流管理）。源老库 M_AllCheck（30,626 行）。
 *
 * <p>不分单据类型，每条 = 一次账户进/出动作（bank register）。运行时由各 finance_*审核 Service 写入：
 * <ul>
 *   <li>{@code source_doc_type=RECEIPT}（BStyle=20）：收款审核 → in_amount</li>
 *   <li>{@code source_doc_type=PAYMENT}（BStyle=21）：付款审核 → out_amount</li>
 *   <li>{@code source_doc_type=INCOME}（BStyle=22）：其它收入审核 → in_amount</li>
 *   <li>{@code source_doc_type=EXPENSE}（BStyle=23）：一般费用审核 → out_amount</li>
 *   <li>{@code source_doc_type=BANK_TRANSFER}（BStyle=27）：银行存取款审核 → in/out 各一行（未来）</li>
 * </ul>
 *
 * <p>立帐动作（AR/AP，BStyle=3/18/1/17/30）一般不写流水（design doc 26 §4.8 已确认）。
 * 报表 S 帐户进出流水帐 / Z 应收应付汇总的核心来源。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "finance_reconciliations")
public class FinanceReconciliation extends SoftDeletableEntity {

    private Integer legacyId;                          // M_AllCheck.ID

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    /** 替代老库 BStyle：RECEIPT/PAYMENT/EXPENSE/INCOME/BANK_TRANSFER（CHECK 约束 5 值）。 */
    @Column(name = "source_doc_type", nullable = false)
    private String sourceDocType;

    /** → finance_receipts/payments/expenses/other_incomes/bank_transfers.id（多态，不 FK）。 */
    @Column(name = "source_doc_id")
    private UUID sourceDocId;

    @Column(name = "account_id")
    private UUID accountId;

    /** CheckNo 支票号/发票号。 */
    @Column(name = "check_no")
    private String checkNo;

    /** Company 对方公司名（客户名/供应商名，迁移时 JOIN 拉取）。 */
    @Column(name = "counterpart_name")
    private String counterpartName;

    @Column(name = "in_amount", precision = 18, scale = 4)
    private BigDecimal inAmount = BigDecimal.ZERO;

    @Column(name = "out_amount", precision = 18, scale = 4)
    private BigDecimal outAmount = BigDecimal.ZERO;

    /** V408 append-only fact kind: POSTING / REVERSAL / ADJUSTMENT. */
    @Column(name = "entry_kind", nullable = false)
    private String entryKind;

    /** V408 reversal lineage; populated only for REVERSAL rows. */
    @Column(name = "reversal_of_id")
    private UUID reversalOfId;

    /** BillDate 发生日期。 */
    @Column(name = "bill_date")
    private OffsetDateTime billDate;

    /** OutDate 核销/支票核销日。 */
    @Column(name = "settled_date")
    private OffsetDateTime settledDate;

    @Column(name = "source_remark")
    private String sourceRemark;

    private String remark;

    /** 老库 BStyle（20/21/22/23/27，保留校验）。 */
    @Column(name = "legacy_bstyle")
    private Integer legacyBstyle;
}
