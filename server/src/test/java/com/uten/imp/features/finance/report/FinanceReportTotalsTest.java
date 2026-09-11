package com.uten.imp.features.finance.report;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 钱流报表「表格下方合计」声明契约。
 *
 * <p>三条最要命的规矩，本类逐条钉死：
 * <ol>
 *   <li>合计跑在与列表同一份 WHERE 上，<b>含对象级授权谓词</b>——否则会把别人的单据算进合计，
 *       等于绕过行级权限泄漏总额；</li>
 *   <li>派生表不带 LIMIT/OFFSET，合计覆盖整个筛选后结果集而不是当前这一页；</li>
 *   <li>原币金额按币别分组、<b>单头金额/时点快照/汇率一律不参与合计</b>。</li>
 * </ol>
 */
class FinanceReportTotalsTest {

    private final EntityManager em = mock(EntityManager.class);
    private final FinanceDocumentAccessPolicy access = mock(FinanceDocumentAccessPolicy.class);
    private final SystemSettingsService settings = mock(SystemSettingsService.class);
    private final com.uten.imp.features.finance.statement.FinanceStatementService statementService =
            mock(com.uten.imp.features.finance.statement.FinanceStatementService.class);
    private final com.uten.imp.features.finance.cost.FinanceCostService costService =
            mock(com.uten.imp.features.finance.cost.FinanceCostService.class);
    private final com.uten.imp.features.finance.gl.GlReportService glReportService =
            mock(com.uten.imp.features.finance.gl.GlReportService.class);
    private final com.uten.imp.features.finance.asset.FixedAssetService fixedAssetService =
            mock(com.uten.imp.features.finance.asset.FixedAssetService.class);

    @Test
    void arApDetailGroupsOriginalAmountsByCurrencyAndRefusesSnapshotsAndRates() {
        seeAll();
        String aggregate = aggregateSqlOf(() -> service().arApDetail(
                "AR", null, null, null, null, null, null, Map.of(), 1, 50, null, null));

        // 原币列按币别分组 —— 绝不跨币种相加。
        assertThat(aggregate).contains("GROUP BY t.\"currencyCode\"");
        assertThat(aggregate).contains("SUM(t.\"amountOriginal\")");
        assertThat(aggregate).contains("SUM(t.\"balanceOriginal\")");
        // 人民币列本就同币，不分组。
        assertThat(aggregate).contains("SUM(t.\"amountLocal\")");
        // 汇率是比率，相加无意义。
        assertThat(aggregate).doesNotContain("SUM(t.\"rate\")");
        // 覆盖整个结果集。
        assertThat(aggregate).doesNotContain("LIMIT").doesNotContain("OFFSET");
    }

    @Test
    void expenseDetailTotalsOnlyTheLineAmountNotTheRepeatedDocumentHeaderAmount() {
        scopedToOwner();
        String aggregate = aggregateSqlOf(() -> service().expenseDetail(
                null, null, null, null, null, null, null, Map.of(), 1, 50, null, null));

        // 行级支出金额可加。
        assertThat(aggregate).contains("SUM(t.\"lineAmount\")");
        // 付款总额/实付金额是费用单**单头**金额，一单多行就会重复计数 —— 绝不合计。
        assertThat(aggregate).doesNotContain("SUM(t.\"amountTotal\")");
        assertThat(aggregate).doesNotContain("SUM(t.\"amountLocal\")");
        // 数量没有随行的单位列、单价是比率 —— 都不合计。
        assertThat(aggregate).doesNotContain("SUM(t.\"qty\")");
        assertThat(aggregate).doesNotContain("SUM(t.\"price\")");
        assertThat(aggregate).doesNotContain("SUM(t.\"lineNo\")");
        // 合计必须带上对象级授权谓词，否则会把别人的费用单算进总额。
        assertThat(aggregate).contains("t.maker_id IN (:financeReportOwners)");
        assertThat(aggregate).doesNotContain("LIMIT").doesNotContain("OFFSET");
    }

    @Test
    void receiptDetailRefusesReferencedLedgerAmountAndBeforeAfterBalances() {
        scopedToOwner();
        String aggregate = aggregateSqlOf(() -> service().receiptDetail(
                null, null, null, null, null, null, null, Map.of(), 1, 50, null, null));

        assertThat(aggregate).contains("SUM(t.\"amountOriginal\")");
        assertThat(aggregate).contains("SUM(t.\"appliedLocal\")");
        // 手续费在投影处已用 ROW_NUMBER() 只挂首行，整集求和恰好每单计一次 → 可加。
        assertThat(aggregate).contains("SUM(t.\"bankFee\")");
        // 被引用的立账金额会在多行重复；收款前/后未收是时点快照。
        assertThat(aggregate).doesNotContain("SUM(t.\"receivableOriginal\")");
        assertThat(aggregate).doesNotContain("SUM(t.\"balanceBeforeOriginal\")");
        assertThat(aggregate).doesNotContain("SUM(t.\"balanceAfterOriginal\")");
    }

    @Test
    void paymentSummaryRefusesCumulativeLedgerSnapshots() {
        scopedToOwner();
        String aggregate = aggregateSqlOf(() -> service().paymentSummary(
                null, null, null, null, null, null, Map.of(), 1, 50, null, null));

        assertThat(aggregate).contains("SUM(t.\"amountTotal\")");
        assertThat(aggregate).contains("GROUP BY t.\"currencyCode\"");
        // 已付/未付/本次余额来自立账台账的累计快照，不是本单发生额。
        assertThat(aggregate).doesNotContain("SUM(t.\"paid\")");
        assertThat(aggregate).doesNotContain("SUM(t.\"unpaid\")");
        assertThat(aggregate).doesNotContain("SUM(t.\"thisBalance\")");
    }

    @Test
    void incomeDetailHasNoLineLevelAmountSoNoAggregateQueryIsIssued() {
        scopedToOwner();
        Query query = emptyQuery();
        when(em.createNativeQuery(anyString())).thenReturn(query);

        service().incomeDetail(null, null, null, null, null, null, null, Map.of(), 1, 50, null, null);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, atLeastOnce()).createNativeQuery(sql.capture());
        // 整张表只有重复的单头金额，没有可加的列 —— 一条聚合查询都不跑。
        assertThat(sql.getAllValues()).noneMatch(s -> s.contains("SUM(t.\""));
    }

    private String aggregateSqlOf(Runnable call) {
        Query query = emptyQuery();
        when(em.createNativeQuery(anyString())).thenReturn(query);

        call.run();

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, atLeastOnce()).createNativeQuery(sql.capture());
        List<String> aggregates = sql.getAllValues().stream()
                .filter(s -> s.startsWith("SELECT ") && s.contains("SUM(t.\""))
                .toList();
        assertThat(aggregates).isNotEmpty();
        return String.join("\n", aggregates);
    }

    /** 公司级账簿入口（Z/A/C/B/D/X）要求全见，否则整体拒绝。 */
    private void seeAll() {
        when(access.scope()).thenReturn(new OwnerVisibility.OwnerScope(true, Set.of()));
    }

    /** 五类钱流单据报表走对象级读取范围：合计必须复用同一谓词。 */
    private void scopedToOwner() {
        UUID owner = UUID.randomUUID();
        OwnerVisibility.OwnerScope scope = new OwnerVisibility.OwnerScope(false, Set.of(owner));
        when(access.scope()).thenReturn(scope);
        lenient().when(access.nativeReadScope(
                        anyString(), anyString(), any(OwnerVisibility.OwnerScope.class)))
                .thenReturn(new DocumentAccessPolicy.NativeReadScope(
                        "(t.maker_id IS NULL OR t.maker_id IN (:financeReportOwners))",
                        "financeReportOwners", Set.of(owner)));
    }

    private FinanceReportService service() {
        return new FinanceReportService(em, access, settings, statementService,
                costService, glReportService, fixedAssetService);
    }

    private Query emptyQuery() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        lenient().when(query.getSingleResult()).thenReturn(0L);
        return query;
    }
}
