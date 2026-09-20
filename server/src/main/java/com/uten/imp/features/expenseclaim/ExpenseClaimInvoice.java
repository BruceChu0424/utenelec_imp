package com.uten.imp.features.expenseclaim;

import com.uten.imp.common.domain.BaseEntity;
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
 * 报销单发票登记（V608）：票据维度的结构化要素，供审批核对、防重复报销与打印。
 *
 * <p>号码规则（国家税务总局公告 2024 年第 11 号）：数电票 20 位号码、无发票代码；
 * 纸质/旧电子票 8 位号码 + 10/12 位代码。「代码+号码」在存活报销单间唯一
 *（{@code expense_claim_invoices_dedup_uq}）= 财会〔2020〕6 号「防止重复入账」硬约束。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "expense_claim_invoices")
public class ExpenseClaimInvoice extends BaseEntity {

    @Column(name = "claim_id", nullable = false)
    private UUID claimId;

    @Column(name = "line_no", nullable = false)
    private int lineNo;

    /** GENERAL/SPECIAL/DIGITAL/PAPER_GENERAL/PAPER_SPECIAL/OTHER。 */
    @Column(name = "invoice_type", nullable = false)
    private String invoiceType = "GENERAL";

    @Column(name = "invoice_code")
    private String invoiceCode;

    @Column(name = "invoice_no", nullable = false)
    private String invoiceNo;

    @Column(name = "issue_date")
    private LocalDate issueDate;

    @Column(name = "seller_name")
    private String sellerName;

    @Column(name = "seller_tax_no")
    private String sellerTaxNo;

    @Column(name = "buyer_name")
    private String buyerName;

    @Column(name = "amount_excl_tax", precision = 18, scale = 2)
    private BigDecimal amountExclTax;

    @Column(name = "tax_amount", precision = 18, scale = 2)
    private BigDecimal taxAmount;

    @Column(name = "total_amount", nullable = false, precision = 18, scale = 2)
    private BigDecimal totalAmount;

    /** UNCHECKED/VERIFIED_MANUAL/MISMATCH。 */
    @Column(name = "check_state", nullable = false)
    private String checkState = "UNCHECKED";

    /** 关联发票影像附件（attachments.id）；附件删除时置空，要素保留。 */
    @Column(name = "attachment_id")
    private UUID attachmentId;

    private String remark;
    @Column(name="buyer_tax_no") private String buyerTaxNo;
    @Column(name="verification_remark") private String verificationRemark;
    @Column(name="verified_at") private java.time.Instant verifiedAt;
    @Column(name="verified_by") private UUID verifiedBy;
    @Column(name="verified_by_name") private String verifiedByName;
}
