package com.uten.imp.features.dashboard.policy;

import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * 政策与监管动态的权威受众映射：不按 AI 或历史数据自由打标，
 * 只由 category 决定谁能看到。
 *
 * 规则（2026-07-31 决策）：
 *   财税类（TAX/SUBSIDY/EXPORT） → FINANCE + GM
 *   检查类（INSPECTION/SAFETY/QUALITY）与其他 → 仅 GM（总经办直属成员）
 *
 * GM 标签只授予「直接在总经办」的人员（部门链 depth=0），
 * 下级部门员工不会经祖先链获得，见 DashboardOverviewService.departmentContext。
 */
public final class PolicyAudiences {

    public static final String FINANCE = "FINANCE";
    public static final String GM = "GM";

    private static final Set<String> FINANCE_AND_GM = Set.of(FINANCE, GM);
    private static final Set<String> GM_ONLY = Set.of(GM);

    private static final Map<String, Set<String>> BY_CATEGORY = Map.of(
            "TAX", FINANCE_AND_GM,
            "SUBSIDY", FINANCE_AND_GM,
            "EXPORT", FINANCE_AND_GM,
            "INSPECTION", GM_ONLY,
            "SAFETY", GM_ONLY,
            "QUALITY", GM_ONLY);

    private PolicyAudiences() {
    }

    /** 返回该分类的权威受众标签集合；未知分类（含 OTHER）仅总经办直属可见。 */
    public static Set<String> forCategory(String category) {
        if (category == null) return GM_ONLY;
        return BY_CATEGORY.getOrDefault(
                category.toUpperCase(Locale.ROOT), GM_ONLY);
    }
}
