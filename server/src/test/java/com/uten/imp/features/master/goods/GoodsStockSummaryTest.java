package com.uten.imp.features.master.goods;

import com.uten.imp.features.master.goods.dto.GoodsStockRow;
import com.uten.imp.features.master.goods.dto.GoodsStockSummary;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 货品详情「库存量」汇总 (ADR-135): 按仓库×颜色一行 (同名不同颜色不合并), 重量千克且可未知,
 * 线边仓列出但不计入合计; 合计重量只加已知重量, 未知的有量行另计行数 (前端「另有 N 处未称」),
 * 有量的行全都未知时合计为 null (绝不当 0)。
 */
class GoodsStockSummaryTest {

    private static final UUID MAIN = UUID.randomUUID();
    private static final UUID SECOND = UUID.randomUUID();
    private static final UUID LINE_SIDE = UUID.randomUUID();
    private static final UUID RED = UUID.randomUUID();
    private static final UUID RED_TWIN = UUID.randomUUID();

    @Test
    void queryGroupsByWarehouseAndColorIdAndKeepsUnknownWeightNull() {
        assertThat(GoodsService.STOCK_SUMMARY_SQL)
                .contains("GROUP BY b.warehouse_id, w.code, w.name, w.is_line_side, b.color_id, c.name")
                .contains("CASE WHEN bool_or(b.qty <> 0 AND b.weight IS NULL) THEN NULL")
                .contains("COALESCE(bool_or(b.weight_estimated), false) AS weight_estimated")
                .contains("w.is_line_side")
                .contains("w.is_accountable")
                .doesNotContain("GROUP BY b.warehouse_id, w.code, w.name, c.name\n");
    }

    @Test
    void lineSideRowsAreListedButNotTotalledAndEstimatesMarkTheTotal() {
        List<Object[]> rows = new ArrayList<>();
        rows.add(row(MAIN, RED, "红", "10", "2.5000", false, false));
        // 另一个也叫「红」的颜色 (不同 id) 各自成行, 不按名字合并。
        rows.add(row(MAIN, RED_TWIN, "红", "4", "1.0000", true, false));
        rows.add(row(LINE_SIDE, RED, "红", "6", null, false, true));

        GoodsStockSummary summary = GoodsService.summarizeStock(rows);

        assertThat(summary.getRows()).hasSize(3);
        assertThat(summary.getRows()).extracting(GoodsStockRow::getColorId).containsExactly(RED, RED_TWIN, RED);
        assertThat(summary.getTotalQty()).isEqualByComparingTo("14");
        assertThat(summary.getTotalWeight()).isEqualByComparingTo("3.5");
        assertThat(summary.getWeightUnknownRows()).isZero();
        assertThat(summary.isWeightEstimated()).isTrue();
        assertThat(summary.getRows().get(2).isLineSide()).isTrue();
        assertThat(summary.getRows().get(2).getWeight()).isNull();
    }

    @Test
    void unknownRowsAreCountedBesideTheKnownTotalInsteadOfCountingAsZero() {
        List<Object[]> rows = new ArrayList<>();
        rows.add(row(MAIN, null, null, "10", "2.5000", true, false));
        rows.add(row(SECOND, null, null, "3", null, false, false));
        rows.add(row(SECOND, RED, "红", "4", null, false, false));
        // 数量 0 的未知行不算「未称」; 线边仓的未知行不计入合计也不计数。
        rows.add(row(SECOND, RED_TWIN, "红", "0", null, false, false));
        rows.add(row(LINE_SIDE, null, null, "6", null, false, true));

        GoodsStockSummary summary = GoodsService.summarizeStock(rows);

        assertThat(summary.getTotalQty()).isEqualByComparingTo("17");
        assertThat(summary.getTotalWeight()).isEqualByComparingTo("2.5");
        assertThat(summary.getWeightUnknownRows()).isEqualTo(2);
        assertThat(summary.isWeightEstimated()).isTrue();
    }

    @Test
    void allStockedRowsUnknownMakesTheTotalUnknownInsteadOfZero() {
        List<Object[]> rows = new ArrayList<>();
        rows.add(row(MAIN, null, null, "0", "0.0000", false, false));
        rows.add(row(SECOND, null, null, "3", null, false, false));

        GoodsStockSummary summary = GoodsService.summarizeStock(rows);

        assertThat(summary.getTotalQty()).isEqualByComparingTo("3");
        assertThat(summary.getTotalWeight()).isNull();
        assertThat(summary.getWeightUnknownRows()).isEqualTo(1);
        assertThat(summary.isWeightEstimated()).isFalse();
    }

    @Test
    void emptyStockTotalsZeroQuantityAndZeroWeight() {
        GoodsStockSummary summary = GoodsService.summarizeStock(List.of());

        assertThat(summary.getTotalQty()).isEqualByComparingTo("0");
        assertThat(summary.getTotalWeight()).isEqualByComparingTo("0");
        assertThat(summary.getWeightUnknownRows()).isZero();
    }

    private static Object[] row(UUID warehouse, UUID color, String colorName, String qty, String weight,
                                boolean estimated, boolean lineSide) {
        return new Object[] {warehouse, "W-" + warehouse.toString().substring(0, 4), "仓", color, colorName,
                new BigDecimal(qty), weight == null ? null : new BigDecimal(weight), estimated, lineSide};
    }
}
