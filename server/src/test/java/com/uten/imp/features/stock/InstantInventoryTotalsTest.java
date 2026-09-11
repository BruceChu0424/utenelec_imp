package com.uten.imp.features.stock;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 即时库存「表格下方合计」契约。
 *
 * <p>即时库存一行 = 一个货品×颜色<b>跨仓聚合</b>，最容易踩的坑是「合计的行集和表格显示的行集不是同一批」。
 * 本类钉死：合计跑在同一段 core 上（分类子树 / 仓库范围 / 含不良品仓开关 / 关键字 全都在里面），
 * 且派生表不带 LIMIT/OFFSET。
 *
 * <p>同样钉死<b>没有合计的两列</b>：多排数量是计划行单位的量（与行上的「单位」列不同口径）、
 * 库存台账金额受 goods:cost:view 脱敏（合计一旦下发就绕过列脱敏泄漏成本总额）。
 */
class InstantInventoryTotalsTest {

    private final StockBalanceRepository balanceRepo = mock(StockBalanceRepository.class);
    private final StockMovementRepository movementRepo = mock(StockMovementRepository.class);
    private final EntityManager em = mock(EntityManager.class);
    private final StockCostMasker costMasker = mock(StockCostMasker.class);

    @Test
    void totalsRunOverTheSameFilteredRowsAsTheTableAndNeverJustThePage() {
        String aggregate = aggregateSql(false, "螺丝");

        // 数量族按单位分组（都是基本单位量，与行上的「单位」列同口径）。
        assertThat(aggregate).contains("SUM(t.\"qty\")");
        assertThat(aggregate).contains("SUM(t.\"pending_qty\")");
        assertThat(aggregate).contains("SUM(t.\"pending_stock_in_qty\")");
        assertThat(aggregate).contains("GROUP BY t.\"unit_name\"");
        // 重量只有一个口径，不分组。
        assertThat(aggregate).contains("SUM(t.\"weight\")");

        // 与表格同一批行：关键字、含不良品仓开关（关=剔除不良仓）、参与核算仓库口径全在派生表里。
        assertThat(aggregate).contains("g.name ILIKE :kw");
        assertThat(aggregate).contains("NOT w.is_defective");
        assertThat(aggregate).contains("w.is_accountable");
        // 覆盖整个结果集，不是当前这一页。
        assertThat(aggregate).doesNotContain("LIMIT").doesNotContain("OFFSET");
    }

    @Test
    void includeDefectiveToggleFlowsIntoTheTotalsExactlyLikeTheList() {
        String aggregate = aggregateSql(true, null);

        // 开关开着 = 不良仓计入：派生表里就不该出现剔除条件（否则合计会比表格少）。
        assertThat(aggregate).contains("w.is_accountable");
        assertThat(aggregate).doesNotContain("NOT w.is_defective");
    }

    @Test
    void maskedCostAndPlanUnitQuantityAreNeverTotalled() {
        String aggregate = aggregateSql(true, null);

        // 库存台账金额受 goods:cost:view 脱敏，合计绝不能绕过列脱敏。
        assertThat(aggregate).doesNotContain("SUM(t.\"cost_amount\")");
        // 多排数量来自生产计划行单位，与「单位」列不是同一口径。
        assertThat(aggregate).doesNotContain("SUM(t.\"more_qty\")");
    }

    private String aggregateSql(boolean includeDefective, String keyword) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        lenient().when(query.getSingleResult()).thenReturn(0L);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        lenient().when(costMasker.canView()).thenReturn(false);

        new StockQueryService(balanceRepo, movementRepo, em, costMasker)
                .instantInventory(null, null, includeDefective, keyword, 1, 20, null, null);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, atLeastOnce()).createNativeQuery(sql.capture());
        List<String> aggregates = sql.getAllValues().stream()
                .filter(s -> s.startsWith("SELECT ") && s.contains("SUM(t.\""))
                .toList();
        assertThat(aggregates).isNotEmpty();
        return String.join("\n", aggregates);
    }
}
