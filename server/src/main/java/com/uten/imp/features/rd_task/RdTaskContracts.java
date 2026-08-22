package com.uten.imp.features.rd_task;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** 工程研发部任务中心契约（Pattern B：纯记录，无 @Entity）。 */
public final class RdTaskContracts {

    private RdTaskContracts() {}

    public record RdTaskRow(
            UUID id,
            String taskNo,
            String title,
            String category,
            String status,
            String priority,
            UUID goodsId,
            String goodsName,
            String goodsCode,
            UUID orderItemId,
            String sourceDocType,
            UUID sourceDocId,
            String sourceDocNo,
            UUID assigneeEmployeeId,
            String assigneeName,
            UUID reporterEmployeeId,
            String reporterName,
            LocalDate dueDate,
            OffsetDateTime startedAt,
            OffsetDateTime completedAt,
            OffsetDateTime createdAt,
            String closeNote,
            long rowVersion,
            List<String> allowedActions) {
        public RdTaskRow {
            allowedActions = allowedActions == null ? List.of() : List.copyOf(allowedActions);
        }
    }

    /** 手动新建研发任务（rd_task:create）。 */
    public record RdTaskInput(
            @NotBlank @Size(max = 200) String title,
            @Size(max = 2000) String description,
            @NotBlank @Pattern(regexp = "^(?:BOM|DESIGN|SAMPLE|TRIAL|ECN|OTHER)$") String category,
            @Pattern(regexp = "^(?:NORMAL|URGENT)$") String priority,
            UUID goodsId,
            UUID assigneeEmployeeId,
            LocalDate dueDate) {}

    /** 标记完成（rd_task:resolve）。 */
    public record ResolveRequest(
            @NotNull @Min(1) Long expectedVersion,
            @Size(max = 1000) String note) {}

    /** 指派工程师（rd_task:assign）。 */
    public record AssignRequest(UUID assigneeEmployeeId) {}
}
