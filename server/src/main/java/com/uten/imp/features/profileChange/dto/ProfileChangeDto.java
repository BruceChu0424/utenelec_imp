package com.uten.imp.features.profilechange.dto;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.Size;

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
            @NotEmpty
            @Size(max = RequestLimits.PROFILE_CHANGES)
            List<@Valid FieldChange> changes,
            @NotBlank @Size(max = 128) String idemKey
    ) {}

    /** 单字段变更。 */
    public record FieldChange(
            @NotBlank @Size(max = 64) String fieldCode,
            @Size(max = 100) String fieldLabel,
            @Size(max = 4000) String newValue
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
            @NotBlank @Size(max = 16) String action,   // "approve" | "reject"
            @Size(max = 1000) String comment   // 驳回意见（reject 必填，approve 可选）
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

    /** HR 队列表头筛选桶（2026-09-10）：部门 value=部门 id、label=部门名、count=该状态下批次数。 */
    public record Facets(List<FacetBucket> departments) {}

    public record FacetBucket(String value, String label, long count) {}

    /** 分页响应。 */
    public record Page<T>(
            List<T> items,
            int page,
            int size,
            long totalElements,
            int totalPages
    ) {}
}
