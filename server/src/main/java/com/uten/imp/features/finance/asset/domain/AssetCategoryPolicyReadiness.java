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
        // 返回中文标签（仅用于展示/报错；ready() 只看 isEmpty，不对字符串值分支），
        // 避免把内部字段名（costStyleId 等）泄露到前端/抓包。
        List<String> missing = new ArrayList<>();
        boolean fixed = "FIXED_ASSET".equals(input.objectType());
        if (!fixed && !"DEFERRED_EXPENSE".equals(input.objectType())) missing.add("类别类型");
        if (input.costStyleId() == null) missing.add("成本科目");
        if (fixed && input.accumulatedStyleId() == null) missing.add("累计折旧科目");
        if (input.expenseStyleId() == null) missing.add("费用科目");
        if (input.clearingStyleId() == null) missing.add("清理科目");
        if (input.method() == null || input.method().isBlank()) missing.add("计提方法");
        else if (!"STRAIGHT_LINE".equals(input.method())) missing.add("支持的计提方法");
        if (input.usefulMonths() == null || input.usefulMonths() < 1 || input.usefulMonths() > 1200) {
            missing.add("使用月份");
        }
        if (fixed && (input.residualRate() == null || input.residualRate().signum() < 0
                || input.residualRate().compareTo(BigDecimal.ONE) > 0)) {
            missing.add("残值率");
        }
        if (input.effectiveFrom() == null) missing.add("生效日期");
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
