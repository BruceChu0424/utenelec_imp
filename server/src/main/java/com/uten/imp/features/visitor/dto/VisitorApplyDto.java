package com.uten.imp.features.visitor.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** 访客申请 / 审批相关 DTO。 */
public final class VisitorApplyDto {
    private VisitorApplyDto() {}

    public record VisitorApplyRequest(
            @NotBlank(message = "访客姓名不能为空")
            @Size(max = 100, message = "访客姓名不能超过100个字符")
            String visitorName,
            @Size(max = 14, message = "手机号过长")
            @Pattern(
                    regexp = "^$|^(?:\\+?86)?1[3-9]\\d{9}$",
                    message = "手机号格式不正确")
            String phone,
            @Size(max = 18, message = "证件号码过长")
            @Pattern(
                    regexp = "^$|^(?:\\d{15}|\\d{17}[0-9Xx])$",
                    message = "身份证号码格式不正确")
            String idCardNo,
            @Size(max = 200, message = "来访单位不能超过200个字符")
            String company,
            @NotBlank(message = "来访事由不能为空")
            @Size(max = 1000, message = "来访事由不能超过1000个字符")
            String visitPurpose,
            boolean hasVehicle,
            @Size(max = 20, message = "车牌号不能超过20个字符")
            String plateNo,
            @NotNull(message = "接待人不能为空")
            UUID hostEmployeeId,
            UUID hostDepartmentId,
            @NotNull(message = "计划到访时间不能为空")
            OffsetDateTime plannedVisitAt,
            OffsetDateTime plannedLeaveAt) {}

    /** 审批动作：approve / reject / forward（转被访人确认）。 */
    public record VisitorApproveRequest(
            @NotBlank(message = "审批动作不能为空")
            @Pattern(
                    regexp = "^(?:approve|reject|forward)$",
                    message = "审批动作不合法")
            String action,
            @Size(max = 1000, message = "审批意见不能超过1000个字符")
            String comment,
            @Size(max = 1000, message = "驳回原因不能超过1000个字符")
            String rejectReason) {}

    /** 被访人确认（可选两级环节）。 */
    public record HostConfirmRequest(
            boolean confirmed,
            @Size(max = 1000, message = "确认意见不能超过1000个字符")
            String comment) {}

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
