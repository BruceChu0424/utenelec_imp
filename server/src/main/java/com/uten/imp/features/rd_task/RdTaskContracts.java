package com.uten.imp.features.rd_task;

import jakarta.validation.constraints.Min;
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
            List<String> allowedActions,
            // 货品身份三件套（名称+编号+颜色）缺一就会认错货：同名货品常按颜色分行
            // （「白色/香槟金」）。颜色取 goods.color_id 主档色，rd_tasks 自身不存颜色。
            // 新字段追加在末尾，不打乱既有位置构造。
            String colorName) {
        public RdTaskRow {
            allowedActions = allowedActions == null ? List.of() : List.copyOf(allowedActions);
        }
    }

    /** 标记完成（rd_task:resolve）。 */
    public record ResolveRequest(
            @NotNull @Min(1) Long expectedVersion,
            @Size(max = 1000) String note) {}
}
