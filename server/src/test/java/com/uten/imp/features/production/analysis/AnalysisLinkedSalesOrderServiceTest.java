package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 关联销售订货单只读投影(ADR-088)的越权闸与字段口径。
 *
 * <p>本页的安全模型是「凭分析查看权看这张分析引用过的订单」，所以两条性质必须钉死：
 * ① 不属于该分析的 orderId 一律 404，不能拿分析 id 当通行证遍历全库订单；
 * ② 返回体里不许出现任何价格列——生产口径看不到销售价格。
 */
class AnalysisLinkedSalesOrderServiceTest {

    private static final UUID ANALYSIS = UUID.randomUUID();
    private static final UUID ORDER = UUID.randomUUID();

    /**
     * 闸一：先按物料分析的对象级范围判定能不能读这张分析。
     *
     * <p>只做「订单属不属于这张分析」那一道闸是不够的——那只挡住了「换订单」，
     * 没挡住「换分析」：拿同事的 analysisId 照样能读到本人无权查看的订单明细，
     * 而本端点刻意不要求 sales_order:view。
     */
    @Test
    void unreadableAnalysisIsRefusedBeforeAnyOrderQuery() {
        RecordingEntityManager em = new RecordingEntityManager(1L, List.of(header(), lines()));
        MaterialAnalysisService analyses = mock(MaterialAnalysisService.class);
        doThrow(new ApiException(ErrorCode.NOT_FOUND, "物料分析不存在"))
                .when(analyses).requireReadableAnalysis(ANALYSIS);
        AnalysisLinkedSalesOrderService service =
                new AnalysisLinkedSalesOrderService(em.entityManager(), analyses);

        assertThatThrownBy(() -> service.linkedOrder(ANALYSIS, ORDER))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("物料分析不存在");
        // 门禁不过就一条 SQL 都不许发：连「这张订单存在吗」都不能泄露。
        assertThat(em.statements).isEmpty();
    }

    @Test
    void unlinkedOrderIsNotFoundInsteadOfLeakingAnyLine() {
        RecordingEntityManager em = new RecordingEntityManager(0L, List.of());
        AnalysisLinkedSalesOrderService service = service(em);

        assertThatThrownBy(() -> service.linkedOrder(ANALYSIS, ORDER))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不在本次物料分析的来源范围内")
                .extracting(error -> ((ApiException) error).getCode())
                .isEqualTo(ErrorCode.NOT_FOUND);
        // 越权闸必须是第一条 SQL：不命中就不允许再发出任何取数查询。
        assertThat(em.statements).hasSize(1);
        assertThat(em.statements.getFirst())
                .contains("production_material_analysis_items")
                .contains("sales_item.order_id = :orderId")
                .contains("analysis_item.analysis_id = :analysisId");
    }

    @Test
    void linkedOrderReturnsEveryLineWithoutAnyPriceColumn() {
        RecordingEntityManager em = new RecordingEntityManager(1L, List.of(header(), lines()));
        AnalysisLinkedSalesOrderService service = service(em);

        var view = service.linkedOrder(ANALYSIS, ORDER);

        assertThat(view.billNo()).isEqualTo("SO-088");
        assertThat(view.clientName()).isEqualTo("客户甲");
        assertThat(view.lines()).hasSize(2);
        // 已交付完的行也在清单里：本页是「这张单订了什么」，不是待办队列。
        assertThat(view.lines()).extracting("goodsCode").containsExactly("A-001", "B-001");
        // 只有本张分析的来源行标 inAnalysis，其余行如实为 false。
        assertThat(view.lines().getFirst().inAnalysis()).isTrue();
        assertThat(view.lines().get(1).inAnalysis()).isFalse();
        assertThat(view.lines().getFirst().outstandingQty()).isEqualByComparingTo("8");
        assertThat(view.lines().getFirst().unplannedQty()).isEqualByComparingTo("5");

        String lineSql = em.statements.get(2);
        assertThat(lineSql)
                .doesNotContain("price")
                .doesNotContain("amount")
                .doesNotContain("discount")
                .doesNotContain("tax");
        // 单头同样不出金额, 也不出自由文本备注(销售备注常写折扣与付款条件)。
        assertThat(em.statements.get(1)).doesNotContain("remark");
        assertThat(AnalysisLinkedSalesOrderService.LinkedSalesOrderView.class.getRecordComponents())
                .extracting(java.lang.reflect.RecordComponent::getName)
                .doesNotContain("remark");
        assertThat(AnalysisLinkedSalesOrderService.LinkedSalesOrderLine.class.getRecordComponents())
                .extracting(java.lang.reflect.RecordComponent::getName)
                .noneSatisfy(name -> assertThat(name.toLowerCase(java.util.Locale.ROOT))
                        .containsAnyOf("price", "amount", "discount", "tax"));
    }

    @Test
    void linkedButMissingOrderHeaderIsNotFound() {
        RecordingEntityManager em = new RecordingEntityManager(1L, List.of(List.<Object[]>of()));
        AnalysisLinkedSalesOrderService service = service(em);

        assertThatThrownBy(() -> service.linkedOrder(ANALYSIS, ORDER))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("销售订货单不存在");
    }

    /** 闸一默认放行，用来单测闸二与字段口径。 */
    private static AnalysisLinkedSalesOrderService service(RecordingEntityManager em) {
        return new AnalysisLinkedSalesOrderService(
                em.entityManager(), mock(MaterialAnalysisService.class));
    }

    private static List<Object[]> header() {
        return List.<Object[]>of(new Object[]{
                "SO-088", java.sql.Date.valueOf("2026-09-01"), java.sql.Date.valueOf("2026-09-20"),
                UUID.randomUUID(), "客户甲", "跟单员乙", (short) 1, Boolean.TRUE,
                Boolean.FALSE, Boolean.FALSE});
    }

    private static List<Object[]> lines() {
        return List.of(
                new Object[]{UUID.randomUUID(), 1, UUID.randomUUID(), "A-001", "产品 A", "规格 A",
                        UUID.randomUUID(), "白色", UUID.randomUUID(), "个",
                        bd("10"), bd("2"), bd("0"), bd("0"), bd("8"),
                        bd("1"), bd("2"), bd("0"), bd("5"),
                        java.sql.Date.valueOf("2026-09-20"), (short) 2, Boolean.TRUE},
                new Object[]{UUID.randomUUID(), 2, UUID.randomUUID(), "B-001", "产品 B", null,
                        null, null, UUID.randomUUID(), "箱",
                        bd("4"), bd("4"), bd("0"), bd("0"), bd("0"),
                        bd("0"), bd("0"), bd("0"), bd("0"),
                        null, (short) 9, Boolean.FALSE});
    }

    private static BigDecimal bd(String value) {
        return new BigDecimal(value);
    }

    /** 记录每条 SQL 并按调用顺序回放预置结果的最小 EntityManager 替身。 */
    private static final class RecordingEntityManager {

        private final long linkedCount;
        private final List<List<Object[]>> resultLists;
        private final List<String> statements = new ArrayList<>();
        private final List<Map<String, Object>> bindings = new ArrayList<>();
        private int resultCursor;

        private RecordingEntityManager(long linkedCount, List<List<Object[]>> resultLists) {
            this.linkedCount = linkedCount;
            this.resultLists = resultLists;
        }

        private EntityManager entityManager() {
            EntityManager em = mock(EntityManager.class);
            when(em.createNativeQuery(anyString())).thenAnswer(call -> {
                statements.add(call.getArgument(0));
                Map<String, Object> bound = new LinkedHashMap<>();
                bindings.add(bound);
                Query query = mock(Query.class);
                when(query.setParameter(anyString(), any())).thenAnswer(bind -> {
                    bound.put(bind.getArgument(0), bind.getArgument(1));
                    return query;
                });
                when(query.getSingleResult()).thenReturn(linkedCount);
                when(query.getResultList()).thenAnswer(ignored ->
                        resultCursor < resultLists.size()
                                ? resultLists.get(resultCursor++)
                                : List.of());
                return query;
            });
            return em;
        }
    }
}
