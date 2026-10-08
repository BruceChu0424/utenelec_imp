package com.uten.imp.features.ai.usage;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

public final class AiUsageDtos {
    private AiUsageDtos() {}
    public record Cost(String currency, String amount, String basis) {}
    public record Summary(long uses, long calls, long okCalls, long localUses, Long inputTokens,
                          Long outputTokens, long unknownTokenCalls, long unknownCostCalls, List<Cost> costs) {}
    public record User(UUID userId, String name, String code, long uses, long calls, long unknownCostCalls, List<Cost> costs) {}
    public record Use(UUID id, UUID jobId, OffsetDateTime createdAt, OffsetDateTime finishedAt,
                      UUID userId, UUID employeeId, String name, String code, String kind, String question,
                      String questionState, String status, String intent, long calls, Long inputTokens,
                      Long outputTokens, long unknownTokenCalls, long unknownCostCalls, List<Cost> costs,
                      List<String> providerNames, List<String> models) {}
    public record Audit(int days, int page, int size, long total, Summary summary, List<User> users, List<Use> records) {}
    /** 套餐额度窗口: key=FIVE_HOURS|WEEKLY; used=平台成功调用次数(自动统计); quota=null 未配置。 */
    public record QuotaWindow(String key, long used, Long quota) {}
    public record Quota(String status, String message, List<QuotaWindow> windows) {}
    public record Billing(UUID providerId, String model, long version, String billingMode, String currency,
                          String inputPerMillion, String outputPerMillion, Long quota5h, Long quotaWeekly,
                          Quota quota) {}
    public record BillingRequest(Long version, String billingMode, String currency, String inputPerMillion,
                                  String outputPerMillion, Integer quota5h, Integer quotaWeekly) {}

    /** 看板 KPI 的今日实时聚合(来自 ai_call_logs)。 */
    public record DashboardKpi(long todayTokens, long todayCalls, long activeUsersToday) {}
    /** 窗口序列的一个桶; 空/零桶也生成, 前端不用补位。 */
    public record SeriesPoint(String bucket, String label, long tokens, long calls, long okCalls) {}
    /** 按人聚合行; 限额两列为 null 表示跟随全局默认; deleted=users 行已删(统计行保留,
     *  展示名回退「已删除员工」); rowVersion=-1 表示还没有限额配置行(首建)。 */
    public record DashboardPerson(UUID userId, String name, String code, String department, boolean deleted,
                                  boolean disabled, Long dailyTokenLimit, Integer dailyJobLimit, long todayTokens,
                                  long windowTokens, long windowCalls, OffsetDateTime lastUsedAt, long rowVersion) {}
    public record Dashboard(String window, long todayTokens, long dailyTokenBudget, long todayCalls,
                            long activeUsersToday, long disabledCount, List<SeriesPoint> series,
                            List<DashboardPerson> people) {}
    /** 人员详情头部(展示名回退链与看板一致)。 */
    public record PersonHead(UUID userId, String name, String code, String department) {}
    /** 人员详情的今日实时聚合(来自 ai_call_logs 按人过滤, 与看板 KPI 同口径)。 */
    public record PersonToday(long todayTokens, long todayCalls) {}
    /** 用途/服务商分布的一个切片; label 为代码原文, 人话由前端既有映射展示。 */
    public record Slice(String label, long calls, long tokens) {}
    public record PersonRecentUse(UUID jobId, String kind, String question, OffsetDateTime createdAt,
                                   String status, long tokens) {}
    public record PersonDetail(UUID userId, String name, String code, String department,
                               long todayTokens, long todayCalls, long dailyTokenBudget,
                               AiUserLimitsService.Limits limits, List<SeriesPoint> series, List<Slice> byPurpose,
                               List<Slice> byProvider, List<PersonRecentUse> recentUses) {}
    public record LimitsRequest(Boolean disabled, Long dailyTokenLimit, Integer dailyJobLimit, Long rowVersion) {}
}
