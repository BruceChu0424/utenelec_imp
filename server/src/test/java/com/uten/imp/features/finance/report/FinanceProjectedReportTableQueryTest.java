package com.uten.imp.features.finance.report;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class FinanceProjectedReportTableQueryTest {
    private static final List<ReportColumn> COLUMNS=List.of(ReportColumn.text("name","名称"),
            ReportColumn.number("qty","数量"),ReportColumn.bool("settled","结清"));

    @Test void declaredIdentifiersAndExactBoundValuesAreSharedByRowsCountsAndFacets() {
        var em=mock(EntityManager.class);
        List<String> statements=new ArrayList<>();
        List<Map<String,Object>> parameters=new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(call->{
            statements.add(call.getArgument(0));
            Map<String,Object> bindings=new LinkedHashMap<>();parameters.add(bindings);
            return mock(Query.class,invocation->switch(invocation.getMethod().getName()) {
                case "setParameter" -> {bindings.put(invocation.getArgument(0),invocation.getArgument(1));yield invocation.getMock();}
                case "getResultList" -> List.of();
                case "getSingleResult" -> 0L;
                default -> RETURNS_DEFAULTS.answer(invocation);
            });
        });
        String hostileValue="x' OR TRUE --";
        FinanceProjectedReportTable.query(em,COLUMNS,"SELECT name,qty,settled FROM authorised_facts",
                query->{},"report.\"name\"",Map.of(new String("name".toCharArray()),hostileValue,
                        "search.qty",">=9007199254740993.0001","settled","true"),
                Set.of("name","settled"),2,20,new String("qty".toCharArray()),"desc",false,List.of());
        assertThat(statements).hasSize(4).allSatisfy(sql->assertThat(sql)
                .doesNotContain(hostileValue,"9007199254740993.0001"));
        assertThat(statements.getFirst()).contains("ORDER BY report.\"qty\" DESC NULLS LAST", ":headerFacet_name",
                "CAST(report.\"qty\" AS numeric)", " >= :column_numeric_qty", ":headerFacet_settled");
        assertThat(parameters.getFirst()).containsEntry("headerFacet_name",hostileValue)
                .containsEntry("column_numeric_qty",new BigDecimal("9007199254740993.0001"))
                .containsEntry("headerFacet_settled",true).containsEntry("__offset",20L);
        assertThat(statements.get(1)).contains("SELECT COUNT(*)", ":headerFacet_name");
        assertThat(statements.stream().filter(sql->sql.contains("GROUP BY report.\"name\"")))
                .singleElement().satisfies(sql->assertThat(sql).doesNotContain(":headerFacet_name")
                        .contains(":headerFacet_settled",":column_numeric_qty"));
    }

    @Test void unknownFacetKeysAndProtectedSearchesFailBeforeAnyQuery() {
        var em=mock(EntityManager.class);
        for(Map<String,String> input:List.of(Map.of("name) OR TRUE --","x"),Map.of("search.__owner","x"))) {
            assertThatThrownBy(()->FinanceProjectedReportTable.query(em,COLUMNS,"SELECT name,qty,settled FROM authorised_facts",
                    query->{},"report.\"name\"",input,Set.of("name"),1,20,null,null,false,List.of()))
                    .isInstanceOf(ApiException.class);
        }
        assertThatThrownBy(()->FinanceProjectedReportTable.query(em,COLUMNS,"SELECT name,qty,settled FROM authorised_facts",
                query->{},"report.\"name\"",Map.of("search.qty","malformed-probe"),Set.of("name"),
                1,20,null,null,false,List.of(),Set.of("qty"))).isInstanceOf(ApiException.class);
        verifyNoInteractions(em);
    }
}
