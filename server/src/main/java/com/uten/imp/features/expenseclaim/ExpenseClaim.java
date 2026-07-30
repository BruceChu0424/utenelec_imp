package com.uten.imp.features.expenseclaim;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import jakarta.persistence.Version;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.util.UUID;

@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "expense_claims")
public class ExpenseClaim extends BaseEntity {

    @Column(name = "applicant_id", nullable = false)
    private UUID applicantId;

    @Column(name = "applicant_name_snapshot", nullable = false)
    private String applicantNameSnapshot;

    @Column(name = "applicant_department_id")
    private UUID applicantDepartmentId;

    @Column(nullable = false)
    private String title;

    @Column(name = "total_amount", nullable = false, precision = 18, scale = 2)
    private BigDecimal totalAmount;

    @Column(nullable = false)
    private String status = "DRAFT";

    private String remark;

    @Column(name = "reject_reason")
    private String rejectReason;

    @Column(name = "submitted_by")
    private UUID submittedBy;

    @Column(name = "approved_by")
    private UUID approvedBy;

    @Column(name = "rejected_by")
    private UUID rejectedBy;

    @Column(name = "paid_by")
    private UUID paidBy;

    @Column(name = "submitted_at")
    private Instant submittedAt;

    @Column(name = "approved_at")
    private Instant approvedAt;

    @Column(name = "rejected_at")
    private Instant rejectedAt;

    @Column(name = "paid_at")
    private Instant paidAt;

    @Column(name = "payment_date")
    private LocalDate paymentDate;

    @Column(name = "payment_account_id")
    private UUID paymentAccountId;

    @Column(name = "payment_expense_style_id")
    private UUID paymentExpenseStyleId;

    @Column(name = "finance_expense_id")
    private UUID financeExpenseId;

    @Version
    @Column(nullable = false)
    private long version;
}
