package com.uten.imp.audit;

import java.util.List;
import java.util.Locale;

/** Shared list/detail/export presentation for person, anonymous, and system actors. */
final class AuditActorPresentation {

    private AuditActorPresentation() {
    }

    static View of(
            AuditLog value,
            AuditActorDirectory.ActorProfile profile) {
        return of(
                value.getActorId() != null,
                value.getActorAccount(),
                value.getAction(),
                value.getEventCategory(),
                value.getEventSource(),
                profile);
    }

    static View of(
            boolean actorIdPresent,
            String actorAccount,
            String action,
            String eventCategory,
            String eventSource,
            AuditActorDirectory.ActorProfile profile) {
        if (actorIdPresent) {
            if (profile != null && !profile.displayName().isBlank()) {
                return new View("人员", profile.displayName());
            }
            String historicalDisplay = actorAccount == null || actorAccount.isBlank()
                    ? "历史人员(档案不可用)"
                    : actorAccount + "(档案不可用)";
            return new View(
                    "历史人员",
                    historicalDisplay);
        }
        if (anonymousEvidence(actorAccount, action, eventCategory, eventSource)) {
            return new View("未识别访问", "未识别访问");
        }
        return new View("系统任务", "系统任务");
    }

    private static boolean anonymousEvidence(
            String actorAccount,
            String actionValue,
            String categoryValue,
            String sourceValue) {
        String account = normalized(actorAccount);
        if (List.of("system", "ops").contains(account)) {
            return false;
        }
        String action = normalized(actionValue);
        String source = normalized(sourceValue);
        String category = normalized(categoryValue);
        return "security".equals(source)
                || List.of("security", "authentication").contains(category)
                || action.contains("login")
                || action.contains("access_denied");
    }

    private static String normalized(String value) {
        return value == null ? "" : value.trim().toLowerCase(Locale.ROOT);
    }

    record View(String actorType, String displayName) {
    }
}
