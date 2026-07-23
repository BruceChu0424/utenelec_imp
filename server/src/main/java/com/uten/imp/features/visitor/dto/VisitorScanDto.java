package com.uten.imp.features.visitor.dto;

import java.time.OffsetDateTime;
import java.util.UUID;

/** 保安扫码核验 + 被访人目录 DTO。 */
public final class VisitorScanDto {
    private VisitorScanDto() {}

    /** 核验入参：qrToken（扫码）与 passcode（手动输入6位码）二选一。 */
    public record VisitorVerifyRequest(String qrToken, String passcode) {}

    /** 核验结果：color = green（放行）/ red（拒绝）。 */
    public record VisitorVerifyResponse(
            boolean valid, String color, String reason,
            UUID applicationId, String visitorName, String visitPurpose,
            String hostName, String plateNo, OffsetDateTime plannedVisitAt,
            OffsetDateTime checkInAt) {}

    /** 被访人候选（排除离职，仅 id/姓名/部门）。 */
    public record EmployeeDirectoryItem(UUID id, String name, String departmentName) {}

    public record DepartmentDirectoryItem(UUID id, String name, UUID parentId) {}
}
