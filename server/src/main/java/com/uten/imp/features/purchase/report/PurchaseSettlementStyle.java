package com.uten.imp.features.purchase.report;

import java.util.Map;
import java.util.Objects;

/**
 * 采购结帐方式字典（源老库 P_Style 小整数，**无字典表**）。
 *
 * <p>现状：老库 P_Order/P_In/P_Withdraw 的 PStyle 是小整数（基本为 1，少量 2/3/4/6/7/8/10），
 * 含义未知。这里留"字典位"——先按原值显示，待业务确认每个码的含义后填入 {@link #LABELS}，
 * 报表单元格即自动由数字变文字。
 */
public final class PurchaseSettlementStyle {

    /**
     * 码 → 标签。**待业务填充**。键为 PStyle 原值（Integer）。
     * 例：put(1, "月结30天"); put(2, "月结60天"); ...
     */
    private static final Map<Integer, String> LABELS = Map.of();

    /** 渲染：未知码回退为原值字符串（便于业务对照排查）。null → null（报表显示空）。 */
    public static String label(Integer code) {
        if (code == null) return null;
        return LABELS.getOrDefault(code, Objects.toString(code));
    }

    private PurchaseSettlementStyle() {}
}
