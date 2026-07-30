package com.uten.imp.features.subcontract.report;

import java.util.Map;
import java.util.Objects;

/**
 * 委外结帐方式字典（源老库 E_In/E_WithDraw.PStyle → B_PStyle.ID）。
 *
 * <p>老库 B_PStyle 字典 8 行（核实自 biz2_pstyle.txt）：1=现金 / 2=提货 / 3=代付 / 4=支票 /
 * 6=月结 / 7=垫付 / 8=汇款 / 10=代收。报表 type=style 的列按本字典渲染成文字。
 * 未知码回退为原值字符串（便于排查）。
 */
public final class SubcontractSettlementStyle {

    private static final Map<Integer, String> LABELS = Map.of(
            1, "现金",
            2, "提货",
            3, "代付",
            4, "支票",
            6, "月结",
            7, "垫付",
            8, "汇款",
            10, "代收"
    );

    /** 渲染：未知码回退为原值字符串；null → null（报表显示空）。 */
    public static String label(Integer code) {
        if (code == null) return null;
        return LABELS.getOrDefault(code, Objects.toString(code));
    }

    private SubcontractSettlementStyle() {}
}
