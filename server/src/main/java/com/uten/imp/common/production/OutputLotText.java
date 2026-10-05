package com.uten.imp.common.production;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;

/**
 * 实物交接批(ADR-148)批内拆分的唯一文案: 登记、品质、点收、车间报工详情都从这里取,
 * 不在各页面各拼一遍。归属优先级本身只由数据库函数 fn_daily_report_output_slice_rank 给出。
 */
public final class OutputLotText {

    /** fn_daily_report_output_slice_rank 的三个取值。 */
    public static final int RANK_DEMAND = 0;
    public static final int RANK_PUBLIC = 1;
    public static final int RANK_ACTUAL_SURPLUS = 2;

    private OutputLotText() {
    }

    /** 份的归属码(给前端标签用): DEMAND 需求份 / PUBLIC 计划公共备货 / ACTUAL_SURPLUS 实际超产。 */
    public static String kind(int rank) {
        return switch (rank) {
            case RANK_ACTUAL_SURPLUS -> "ACTUAL_SURPLUS";
            case RANK_PUBLIC -> "PUBLIC";
            default -> "DEMAND";
        };
    }

    /** 份的大白话名称。 */
    public static String kindLabel(int rank) {
        return switch (rank) {
            case RANK_ACTUAL_SURPLUS -> "实际超产";
            case RANK_PUBLIC -> "计划公共备货";
            default -> "需求";
        };
    }

    /**
     * 批内拆分说明, 如「需求 1000 · 实际超产 100」。整批都是需求份(最常见)时返回 null, 页面不必多显示一行。
     */
    public static String split(BigDecimal demand, BigDecimal publicQty, BigDecimal actualSurplus) {
        List<String> parts = new ArrayList<>(3);
        if (positive(demand)) parts.add("需求 " + plain(demand));
        if (positive(publicQty)) parts.add("计划公共备货 " + plain(publicQty));
        if (positive(actualSurplus)) parts.add("实际超产 " + plain(actualSurplus));
        if (parts.isEmpty() || (parts.size() == 1 && positive(demand))) return null;
        return String.join(" · ", parts);
    }

    /** 「其中实际超产 100」; 没有实际超产时返回 null。 */
    public static String actualSurplusNote(BigDecimal actualSurplus) {
        return positive(actualSurplus) ? "其中实际超产 " + plain(actualSurplus) : null;
    }

    /** 数量文字: 去掉尾零, 不用科学计数法。 */
    public static String plain(BigDecimal value) {
        return value == null ? "0" : value.stripTrailingZeros().toPlainString();
    }

    private static boolean positive(BigDecimal value) {
        return value != null && value.signum() > 0;
    }
}
