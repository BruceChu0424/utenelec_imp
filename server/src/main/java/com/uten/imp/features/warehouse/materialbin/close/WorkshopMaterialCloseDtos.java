package com.uten.imp.features.warehouse.materialbin.close;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 车间内料仓自动结算的请求与响应 (ADR-131 §5.8、§5.9, 规格 §2.3)。
 *
 * <p>{@code allowedActions} 由服务端按当前主体的权限码与期间状态算好 (CLOSE_RETRY / REOPEN), 页面只看它。
 */
public final class WorkshopMaterialCloseDtos {

    private WorkshopMaterialCloseDtos() {}

    /** 最近一次有效结算。 */
    public record LastClose(int closeNo, OffsetDateTime closedAt, String closedByName, String triggerKind) {}

    /**
     * 一期的结算状态 (页面每 2 秒轮询, 最多 60 秒)。
     *
     * @param lastErrorMessage 最近一次失败的业务文案 (不含程序信息); 没有失败为空
     * @param blockers         差什么、谁来补: [{kind, count, responsible, samples}]
     */
    public record CloseStatusView(UUID periodId, UUID binWarehouseId, UUID workshopDepartmentId, int periodNo,
                                  LocalDate startDate, LocalDate endDate, String status, String closeState,
                                  int attempts, int failures, OffsetDateTime attemptedAt, String lastErrorMessage,
                                  List<Map<String, Object>> blockers, OffsetDateTime heldUntil, LastClose lastClose,
                                  long rowVersion, List<String> allowedActions) {}

    /** "立即重试" / "重新结算"。 */
    public record RetryRequest(String idempotencyKey) {}

    /** 撤销结算: 期间行版本 + 原因 (2 到 500 个字)。 */
    public record ReopenRequest(Long expectedVersion, String reason, String idempotencyKey) {}
}
