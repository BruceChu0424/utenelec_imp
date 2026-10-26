package com.uten.imp.common.report;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;

import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Runs all independent metadata combinations through every actual domain executor. */
class ReportReadPlanDomainsTest {
    @TestFactory
    Stream<DynamicTest> everyDomainSharesTheReadPlanWithoutChangingRowsPrecisionOrScope() {
        return Stream.of("sales", "purchase", "subcontract", "production", "stock", "finance")
                .flatMap(domain -> java.util.stream.IntStream.range(0, 8).mapToObj(mask ->
                        DynamicTest.dynamicTest(domain + " metadata=" + mask, () -> verify(domain, mask))));
    }

    private static void verify(String domain, int mask) throws Exception {
        BigDecimal exact = new BigDecimal("1234567890123.123456789");
        List<String> sql = new ArrayList<>();
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String statement = invocation.getArgument(0);
            sql.add(statement);
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), any())).thenReturn(query);
            when(query.getSingleResult()).thenReturn(7L);
            List<?> result = statement.contains("COUNT(*) AS cnt")
                    ? List.<Object[]>of(new Object[]{"a", "供应商", 3L})
                    : List.<Object[]>of(new Object[]{exact});
            when(query.getResultList()).thenReturn(result);
            return query;
        });
        String prefix = "com.uten.imp.features." + domain + ".report.";
        Class<?> serviceType = Class.forName(prefix + Character.toUpperCase(domain.charAt(0))
                + domain.substring(1) + "ReportService");
        Constructor<?> constructor = serviceType.getConstructors()[0];
        Object[] dependencies = Arrays.stream(constructor.getParameterTypes())
                .map(type -> type == EntityManager.class ? em : mock(type)).toArray();
        Object service = constructor.newInstance(dependencies);
        Method execute = Arrays.stream(serviceType.getDeclaredMethods())
                .filter(method -> method.getName().equals("execute")).findFirst().orElseThrow();
        execute.setAccessible(true);
        Class<?> whereType = execute.getParameterTypes()[3];
        Constructor<?> whereConstructor = whereType.getDeclaredConstructor(String.class);
        whereConstructor.setAccessible(true);
        Object where = whereConstructor.newInstance("WHERE o.allowed=true");
        Method add = whereType.getMethod("add", String.class, String.class, Object.class);
        add.setAccessible(true);
        add.invoke(where, "o.owner_id=:owner", "owner", UUID.randomUUID());
        Class<?> columnType = Class.forName(prefix + "ReportColumn");
        Object column = columnType.getMethod("number", String.class, String.class).invoke(null, "qty", "数量");
        column = columnType.getMethod("totaled", String.class).invoke(column, "合计");
        var spec = new ReportQueryKit.FacetSpec("kind", "o.kind AS v,o.kind AS lbl", "o.kind", "o.kind", "text");
        var plan = new ReportReadPlan((mask & 1) != 0, (mask & 2) != 0, (mask & 4) != 0);
        Object response;
        try (var ignored = ReportReadPlan.open(plan)) {
            response = execute.invoke(service, List.of(column), "SELECT o.qty AS \"qty\"", "FROM facts o",
                    where, "o.id", List.of(spec), Map.of("kind", "selected"), 2, 50, "qty", "desc");
        }
        assertThat(ReportReadPlan.current()).isEqualTo(ReportReadPlan.ALL);
        assertThat(sql).hasSize(1 + (plan.includeCount() ? 1 : 0)
                + (plan.includeFacets() ? 1 : 0) + (plan.includeTotals() ? 1 : 0));
        assertThat(sql).allSatisfy(statement -> assertThat(statement).contains("o.allowed=true", "o.owner_id=:owner"));
        assertThat(sql.getFirst()).contains("ORDER BY \"qty\" DESC, o.id", "LIMIT :__limit OFFSET :__offset");
        Class<?> responseType = response.getClass();
        assertThat(responseType.getMethod("total").invoke(response)).isEqualTo(plan.includeCount() ? 7L : -1L);
        assertThat(responseType.getMethod("totalPages").invoke(response)).isEqualTo(plan.includeCount() ? 1 : -1);
        @SuppressWarnings("unchecked")
        List<Map<String, Object>> rows = (List<Map<String, Object>>) responseType.getMethod("rows").invoke(response);
        assertThat(rows).hasSize(1);
        assertThat(rows.getFirst()).containsEntry("qty", exact).containsEntry("qtyExact", exact.toPlainString());
        Map<?, ?> facets = (Map<?, ?>) responseType.getMethod("facets").invoke(response);
        assertThat(facets.size()).isEqualTo(plan.includeFacets() ? 1 : 0);
        List<?> totals = (List<?>) responseType.getMethod("totals").invoke(response);
        assertThat(totals.size()).isEqualTo(plan.includeTotals() ? 1 : 0);
    }
}
