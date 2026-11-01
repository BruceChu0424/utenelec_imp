package com.uten.imp.features.sales;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.Column;
import jakarta.persistence.Embeddable;
import lombok.Getter;
import lombok.Setter;
import java.time.OffsetDateTime;
import java.util.UUID;

/** The sales department decision is independent of the subsequent finance decision. */
@Embeddable
@Getter
@Setter
public class SalesManagerReview {
    public static final String NOT_REQUIRED = "NOT_REQUIRED";
    public static final String PENDING = "PENDING";
    public static final String APPROVED = "APPROVED";
    public static final String REJECTED = "REJECTED";

    @Column(name = "manager_review_state", nullable = false)
    private String state = NOT_REQUIRED;
    @Column(name = "manager_approved_at")
    private OffsetDateTime approvedAt;
    @Column(name = "manager_approved_by")
    private UUID approvedBy;
    @Column(name = "manager_rejected_at")
    private OffsetDateTime rejectedAt;
    @Column(name = "manager_rejected_by")
    private UUID rejectedBy;
    @Column(name = "manager_reject_reason")
    private String rejectReason;
    @Column(name = "manager_review_remark")
    private String remark;

    @Column(name = "manager_decision_claim_id")
    private UUID decisionClaimId;

    public boolean pending() { return PENDING.equals(state); }
    public boolean approved() { return APPROVED.equals(state); }
    public boolean rejected() { return REJECTED.equals(state); }
    public boolean financeReady() { return NOT_REQUIRED.equals(state) || approved(); }
    public void requireFinanceReady() {
        if (!financeReady()) throw new ApiException(ErrorCode.CONFLICT, "须先通过销售负责人审核，才能办理财务审核");
    }
    public void submit() { state = PENDING; decisionClaimId = null; }
    public void approve(UUID actor, String note) {
        state = APPROVED;
        approvedAt = OffsetDateTime.now();
        approvedBy = actor;
        remark = note;
    }
    public void reject(UUID actor, String reason) {
        state = REJECTED;
        rejectedAt = OffsetDateTime.now();
        rejectedBy = actor;
        rejectReason = reason;
    }
}
