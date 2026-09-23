package com.uten.imp.features.visitor.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.time.OffsetDateTime;
import java.util.UUID;

/** 保安扫码核验 + 被访人目录 DTO。 */
public final class VisitorScanDto {
    private VisitorScanDto() {}

    /** 核验入参：qrToken（扫码）与 passcode（手动输入6位码）二选一。 */
    public record VisitorVerifyRequest(
            @Size(max = 1_024, message = "二维码令牌过长")
            String qrToken,
            @Pattern(regexp = "^\\d{6}$", message = "手工核验码必须为 6 位数字")
            String passcode) {}

    /** 核验结果：color = green（放行）/ red（拒绝）。visitorId 供持拉黑权限者定位访客账号。 */
    public record VisitorVerifyResponse(
            boolean valid, String color, String reason,
            UUID applicationId, UUID visitorId, String visitorName,
            String visitPurpose, String hostName, String plateNo,
            OffsetDateTime plannedVisitAt, OffsetDateTime checkInAt) {}

    /** 拉黑请求：原因必填（同步审计）。 */
    public record BlacklistRequest(
            @NotBlank(message = "拉黑原因不能为空")
            @Size(max = 200, message = "拉黑原因不能超过200个字符")
            String reason) {}

    /** 黑名单列表项（管理页，phone 为解密后完整号码，与审批详情同一暴露级别）。 */
    public record BlacklistListItem(
            UUID id, String visitorNo, String name, String phone,
            String blockedReason, OffsetDateTime blockedAt,
            String blockedByName) {}

    /** 访客可选的接待人(可对外接待的在职员工；只有 id 和姓名，不带部门)。 */
    public record EmployeeDirectoryItem(UUID id, String name) {}

}
