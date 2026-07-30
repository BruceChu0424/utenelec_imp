package com.uten.imp.features.sales.report;

import java.util.Map;
import java.util.Objects;

/**
 * 销售结帐方式字典（源老库 PStyle 小整数 → sales_*.payment_style_id，**无字典表**）。
 *
 * <p>现状（与采购 PurchaseSettlementStyle 同型）：老库 S_Order/S_Out/S_OtherOut/S_Withdraw 的 PStyle
 * 是小整数（样本多为 8，少量 1/6），含义未完全确认。这里留"字典位"——先按原值显示，
 * 待业务确认每个码含义后填入 {@link #LABELS}，报表单元格即自动由数字变文字。
 */
public final class SalesSettlementStyle {

    /**
     * 码 → 标签。**待业务填充**。键为 PStyle 原值（Integer）。
     * 例：put(8, "月结30天"); put(1, "货到付款"); ...
     */
    private static final Map<Integer, String> LABELS = Map.of();

    /** 渲染：未知码回退为原值字符串（便于业务对照排查）。null → null（报表显示空）。 */
    public static String label(Integer code) {
        if (code == null) return null;
        return LABELS.getOrDefault(code, Objects.toString(code));
    }

    private SalesSettlementStyle() {}
}
