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
    public record Quota(String status, String message, List<Object> windows) {}
    public record Billing(UUID providerId, String model, long version, String billingMode, String currency,
                          String inputPerMillion, String outputPerMillion, Quota quota) {}
    public record BillingRequest(Long version, String billingMode, String currency, String inputPerMillion, String outputPerMillion) {}
}
