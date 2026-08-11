package com.uten.imp.features.finance.asset.domain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.util.Map;
import java.util.Set;

/** Explicit workflow transitions shared by command services and contract tests. */
public final class FinanceAssetStateMachine {

    private static final Map<String, Set<String>> OBJECT_TRANSITIONS = Map.of(
            "DRAFT", Set.of("PENDING_APPROVAL"),
            "PENDING_APPROVAL", Set.of("DRAFT", "APPROVED"),
            "APPROVED", Set.of("ACTIVE"),
            "ACTIVE", Set.of("DISPOSAL_PENDING", "TERMINATION_PENDING", "COMPLETED"),
            "DISPOSAL_PENDING", Set.of("ACTIVE", "DISPOSED"),
            "TERMINATION_PENDING", Set.of("ACTIVE", "COMPLETED", "TERMINATED"));

    private static final Map<String, Set<String>> RUN_TRANSITIONS = Map.of(
            "PREVIEWED", Set.of("SUBMITTED"),
            "SUBMITTED", Set.of("APPROVED"),
            "APPROVED", Set.of("POSTED"),
            "POSTED", Set.of("REVERSED"));

    private FinanceAssetStateMachine() {}

    public static void requireObjectTransition(String current, String target) {
        requireTransition("asset object", OBJECT_TRANSITIONS, current, target);
    }

    public static void requireRunTransition(String current, String target) {
        requireTransition("posting run", RUN_TRANSITIONS, current, target);
    }

    public static void requireDraft(String current) {
        if (!"DRAFT".equals(current)) {
            throw new ApiException(ErrorCode.CONFLICT, "Only a draft can be edited or deleted");
        }
    }

    private static void requireTransition(
            String subject,
            Map<String, Set<String>> transitions,
            String current,
            String target) {
        if (!transitions.getOrDefault(current, Set.of()).contains(target)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "Invalid " + subject + " transition: " + current + " -> " + target);
        }
    }
}
