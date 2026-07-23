package com.uten.imp.features.profileChange.dto;

import com.fasterxml.jackson.annotation.JsonInclude;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * 员工个人信息修改申请相关 DTO。
 */
public final class ProfileChangeDto {

    private ProfileChangeDto() {}

    /** 员工提交修改申请。 */
    public record SubmitRequest(
            UUID batchId,
            List<FieldChange> changes,
            String idemKey
    ) {}

    /** 单字段变更。 */
    public record FieldChange(
            String fieldCode,
            String fieldLabel,
            String newValue
    ) {}

    /** 提交结果：批次 + 各字段 id。 */
    public record SubmitResponse(
            UUID batchId,
            List<UUID> requestIds,
            int count
    ) {}

    /** 单条申请记录（响应）。 */
    @JsonInclude(JsonInclude.Include.NON_NULL)
    public record Item(
            UUID id,
            UUID batchId,
            String fieldCode,
            String fieldLabel,
            String fieldGroup,
            String oldValue,
            String newValue,
            String status,
            UUID submittedBy,
            String submittedByName,
            OffsetDateTime submittedAt,
            UUID reviewedBy,
            String reviewedByName,
            OffsetDateTime reviewedAt,
            String reviewComment,
            Integer employeeVersion
    ) {}

    /** 批次详情（含 diff）。 */
    public record BatchDetail(
            UUID batchId,
            UUID employeeId,
            String employeeName,
            String employeeCode,
            String status,
            int itemCount,
            List<Item> items,
            OffsetDateTime submittedAt,
            String submittedByName,
            OffsetDateTime reviewedAt,
            String reviewedByName,
            String reviewComment
    ) {}

    /** HR 审批动作。 */
    public record ReviewAction(
            String action,   // "approve" | "reject"
            String comment   // 驳回意见（reject 必填，approve 可选）
    ) {}

    /** 员工自查列表项。 */
    public record MyListItem(
            UUID batchId,
            String status,
            int itemCount,
            OffsetDateTime submittedAt,
            OffsetDateTime reviewedAt,
            String reviewComment,
            List<String> fieldCodes,
            List<String> fieldLabels
    ) {}

    /** HR 队列列表项。 */
    public record HrListItem(
            UUID batchId,
            UUID employeeId,
            String employeeName,
            String employeeCode,
            String departmentName,
            String status,
            int itemCount,
            List<String> fieldCodes,
            OffsetDateTime submittedAt,
            OffsetDateTime reviewedAt,
            String reviewedByName
    ) {}

    /** 分页响应。 */
    public record Page<T>(
            List<T> items,
            int page,
            int size,
            long totalElements,
            int totalPages
    ) {}
}