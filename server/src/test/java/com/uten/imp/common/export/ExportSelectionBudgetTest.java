package com.uten.imp.common.export;

import org.junit.jupiter.api.Test;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

class ExportSelectionBudgetTest {
    @Test void fiftyThousandAndOneGenericSelectorsKeepExactScopeAndStillRequireEveryRow() {
        var selectors=java.util.stream.IntStream.range(0,50001)
                .mapToObj(i->Map.of("code","S"+i)).toList();
        var projection=new TableColumnProjection("master.test","master_unit",
                List.of(new TableColumnProjection.Column("code","编号",100d,"text",null)),selectors);
        var selector=new ExportRowSelection(projection);
        int matched=0;
        for(int start=0;start<50002;start+=100) {
            var rows=new ArrayList<Map<String,Object>>();
            for(int i=start;i<Math.min(start+100,50002);i++) rows.add(Map.of("code","S"+i));
            var result=selector.select(List.of(new ExportColumn("code","编号",ExportColumn.TEXT)),rows);
            matched+=result.size();
        }
        assertThat(matched).isEqualTo(50001);
        selector.verifyComplete();
        var incomplete=new ExportRowSelection(projection);
        assertThatThrownBy(incomplete::verifyComplete).hasMessageContaining("已变化");
    }
    @Test void memoryBudgetRejectsOversizedTextWithoutChangingTheRowCountContract() {
        var selectors=java.util.stream.IntStream.range(0,200)
                .mapToObj(i->Map.of("code",("S"+i)+"x".repeat(100000-5))).toList();
        assertThatThrownBy(()->ExportSelectionBudget.requireRows(selectors))
                .hasMessageContaining("空间预算");
    }
    @Test void uuidSelectionBeyondFiftyThousandParsesAndDuplicateOrMissingNeverBecomesAll() throws Exception {
        var ids=java.util.stream.IntStream.range(0,50001).mapToObj(i->new UUID(1,i+1)).toList();
        var json=new com.fasterxml.jackson.databind.ObjectMapper();
        assertThat(MasterExportSelection.parse(json.writeValueAsString(ids),json)).containsExactlyElementsOf(ids);
        try(var scope=MasterExportSelection.open(ids)) {
            assertThatThrownBy(()->MasterExportSelection.requireComplete(50002)).hasMessageContaining("本次未生成文件");
        }
        assertThatThrownBy(()->MasterExportSelection.open(List.of(ids.getFirst(),ids.getFirst())))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThat(MasterExportSelection.current()).isNull();
    }
}
