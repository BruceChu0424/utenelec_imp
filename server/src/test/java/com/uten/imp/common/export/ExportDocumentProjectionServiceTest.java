package com.uten.imp.common.export;

import com.uten.imp.common.platformcolumns.PlatformColumnService;
import com.uten.imp.common.platformcolumns.PlatformColumnContracts.*;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class ExportDocumentProjectionServiceTest {
    @Test void costDisplayHelperUsesFrozenAmountsAndNeverRereadsLiveBusinessRows() {
        var platform=mock(PlatformColumnService.class);
        UUID id=UUID.randomUUID();
        var definition=new Definition(id,"view_goods_cost","金额对照","CALCULATED",true,
                new Formula(new Operand(null,"amount",null),List.of()),0,0);
        when(platform.definitionsByIds("view_goods_cost",List.of(id))).thenReturn(List.of(definition));
        when(platform.evaluateDisplayRows(eq("view_goods_cost"),eq(List.of(id)),any())).thenAnswer(invocation->{
            List<Map<String,BigDecimal>> facts=invocation.getArgument(2);
            assertThat(facts.getFirst().get("amount")).isEqualByComparingTo("1.00000000000000001");
            return List.of(Map.of(id,"1.00000000000000001"));
        });
        var service=new ExportDocumentProjectionService(new ExportTableProjectionService(platform));
        var document=new ExportDocument("成本",List.of("冻结版本"),List.of(new ExportDocument.Section("物料明细",
                List.of(new ExportColumn("amount","行成本",ExportColumn.QTY)),List.of(Map.of("amount",new BigDecimal("1.00000000000000001"))))));
        var projection=new TableColumnProjection("master.goods.cost.items","view_goods_cost",List.of(
                new TableColumnProjection.Column("platform:"+id,"客户端伪标签",120d,"text",null)));
        var result=service.project(document,projection,"物料明细","view_goods_cost");
        assertThat(result.sections().getFirst().columns().getFirst().label()).isEqualTo("金额对照");
        assertThat(result.sections().getFirst().rows().getFirst().get("platform:"+id)).isEqualTo("1.00000000000000001");
        verify(platform,never()).read(anyString(),any());
    }
}
