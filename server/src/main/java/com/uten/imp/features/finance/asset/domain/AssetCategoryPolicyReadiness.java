package com.uten.imp.features.finance.asset.domain;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** Reports missing enterprise policy without inventing system defaults. */
public final class AssetCategoryPolicyReadiness {

    private AssetCategoryPolicyReadiness() {}

    public static List<String> missing(Input input) {
        List<String> missing = new ArrayList<>();
        boolean fixed = "FIXED_ASSET".equals(input.objectType());
        if (!fixed && !"DEFERRED_EXPENSE".equals(input.objectType())) missing.add("objectType");
        if (input.costStyleId() == null) missing.add("costStyleId");
        if (fixed && input.accumulatedStyleId() == null) missing.add("accumulatedStyleId");
        if (input.expenseStyleId() == null) missing.add("expenseStyleId");
        if (input.clearingStyleId() == null) missing.add("clearingStyleId");
        if (input.method() == null || input.method().isBlank()) missing.add("defaultMethod");
        else if (!"STRAIGHT_LINE".equals(input.method())) missing.add("supportedDefaultMethod");
        if (input.usefulMonths() == null || input.usefulMonths() < 1 || input.usefulMonths() > 1200) {
            missing.add("defaultUsefulMonths");
        }
        if (fixed && (input.residualRate() == null || input.residualRate().signum() < 0
                || input.residualRate().compareTo(BigDecimal.ONE) > 0)) {
            missing.add("defaultResidualRate");
        }
        if (input.effectiveFrom() == null) missing.add("effectiveFrom");
        return List.copyOf(missing);
    }

    public static boolean ready(Input input) {
        return missing(input).isEmpty();
    }

    public record Input(
            String objectType,
            UUID costStyleId,
            UUID accumulatedStyleId,
            UUID expenseStyleId,
            UUID clearingStyleId,
            String method,
            Integer usefulMonths,
            BigDecimal residualRate,
            LocalDate effectiveFrom) {}
}
