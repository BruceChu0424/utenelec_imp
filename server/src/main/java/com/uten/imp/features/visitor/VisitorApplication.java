package com.uten.imp.features.visitor;

import com.uten.imp.common.domain.SoftDeletableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 访客来访申请。状态机：pending → hostReviewing(可选) → approved/rejected → checkedIn。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "visitor_applications")
public class VisitorApplication extends SoftDeletableEntity {

    @Column(name = "visitor_account_id")
    private UUID visitorAccountId;

    @Column(name = "visitor_name", nullable = false)
    private String visitorName;

    @Column(name = "phone_enc")
    private String phoneEnc;

    @Column(name = "id_card_enc")
    private String idCardEnc;

    @Column(name = "id_card_last4")
    private String idCardLast4;

    private String company;

    @Column(name = "visit_purpose", nullable = false)
    private String visitPurpose;

    @Column(name = "has_vehicle", nullable = false)
    private boolean hasVehicle;

    @Column(name = "plate_no")
    private String plateNo;

    @Column(name = "plate_no_enc")
    private String plateNoEnc;

    @Column(name = "host_employee_id")
    private UUID hostEmployeeId;

    @Column(name = "host_department_id")
    private UUID hostDepartmentId;

    @Column(name = "planned_visit_at", nullable = false)
    private OffsetDateTime plannedVisitAt;

    @Column(name = "planned_leave_at")
    private OffsetDateTime plannedLeaveAt;

    @Column(nullable = false)
    private String status = "pending";

    @Column(name = "applied_at", nullable = false)
    private OffsetDateTime appliedAt = OffsetDateTime.now();

    @Column(name = "approved_by")
    private UUID approvedBy;

    @Column(name = "approved_at")
    private OffsetDateTime approvedAt;

    @Column(name = "reject_reason")
    private String rejectReason;

    /** 被访人确认（两级审批可选）：null=未走该环节，true=同意，false=拒绝。 */
    @Column(name = "host_confirmed")
    private Boolean hostConfirmed;

    @Column(name = "check_in_at")
    private OffsetDateTime checkInAt;

    /** HR 批准后签发的入场二维码凭证（HMAC 签名）。 */
    @Column(name = "qr_token", unique = true)
    private String qrToken;

    /** 6位短码：二维码无法扫描时保安手动输入核验。 */
    @Column(name = "passcode")
    private String passcode;
}
