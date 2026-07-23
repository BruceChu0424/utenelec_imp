package com.uten.imp.features.visitor.dto;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** 访客申请 / 审批相关 DTO。 */
public final class VisitorApplyDto {
    private VisitorApplyDto() {}

    public record VisitorApplyRequest(
            String visitorName, String phone, String idCardNo, String company,
            String visitPurpose, boolean hasVehicle, String plateNo,
            UUID hostEmployeeId, UUID hostDepartmentId,
            OffsetDateTime plannedVisitAt, OffsetDateTime plannedLeaveAt) {}

    /** 审批动作：approve / reject / forward（转被访人确认）。 */
    public record VisitorApproveRequest(String action, String comment, String rejectReason) {}

    /** 被访人确认（可选两级环节）。 */
    public record HostConfirmRequest(boolean confirmed, String comment) {}

    public record VisitorApprovalStepDto(
            String action, String actorType, String actorName, OffsetDateTime actedAt, String comment) {}

    public record VisitorListItem(
            UUID id, String visitorName, String company, String visitPurpose,
            String hostName, String hostDepartment,
            OffsetDateTime plannedVisitAt, OffsetDateTime plannedLeaveAt,
            String status, OffsetDateTime appliedAt, OffsetDateTime approvedAt,
            boolean hasVehicle, String plateNo) {}

    public record VisitorDetail(
            UUID id, String visitorName, String phone, String idCardLast4,
            String company, String visitPurpose, boolean hasVehicle, String plateNo,
            String hostName, String hostDepartment,
            OffsetDateTime plannedVisitAt, OffsetDateTime plannedLeaveAt,
            String status, OffsetDateTime appliedAt, OffsetDateTime approvedAt,
            String rejectReason, Boolean hostConfirmed, OffsetDateTime checkInAt,
            String qrToken, String passcode, List<VisitorApprovalStepDto> steps) {}
}
