package com.uten.imp.features.purchase.report;

import java.util.Map;
import java.util.Objects;

/**
 * 采购结帐方式字典（源老库 {@code B_PStyle}，P_Order/P_In/P_Withdraw.PStyle → B_PStyle.ID）。
 *
 * <p>字典内容 2026-07-28 从老库 B_PStyle 实查固化（老库无在线字典接口，值十几年稳定，
 * 与迁移脚本 migrate_purchase.sql 头部注释同源）：
 * 1现金 / 2提货 / 3代付 / 4支票 / 6月结 / 7垫付(托运部垫付) / 8汇款 / 10代收。
 * 老库存在跳号（无 5/9），未知码回退原值便于排查。
 */
public final class PurchaseSettlementStyle {

    /** 码 → 标签。键为 PStyle 原值（= B_PStyle.ID）。 */
    private static final Map<Integer, String> LABELS = Map.of(
            1, "现金",
            2, "提货",
            3, "代付",
            4, "支票",
            6, "月结",
            7, "垫付",
            8, "汇款",
            10, "代收");

    /** 渲染：未知码回退为原值字符串（便于业务对照排查）。null → null（报表显示空）。 */
    public static String label(Integer code) {
        if (code == null) return null;
        return LABELS.getOrDefault(code, Objects.toString(code));
    }

    private PurchaseSettlementStyle() {}
}
