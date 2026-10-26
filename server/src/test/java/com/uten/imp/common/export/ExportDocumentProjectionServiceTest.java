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
    @Test void streamedSectionsMatchTheOriginalProjectionWithoutDroppingOtherEvidenceOrChangingPrecision() {
        var platform=mock(PlatformColumnService.class);UUID id=UUID.randomUUID();
        var definition=new Definition(id,"view_goods_cost","冻结公式","CALCULATED",true,
                new Formula(new Operand(null,"amount",null),List.of()),0,0);
        when(platform.definitionsByIds("view_goods_cost",List.of(id))).thenReturn(List.of(definition));
        var streaming=new java.util.concurrent.atomic.AtomicBoolean();
        when(platform.evaluateDisplayRows(eq("view_goods_cost"),eq(List.of(id)),any())).thenAnswer(call->{
            List<Map<String,BigDecimal>> facts=call.getArgument(2);
            if(streaming.get())assertThat(facts.size()).isLessThanOrEqualTo(200);
            return facts.stream().map(row->Map.of(id,row.get("amount").toPlainString())).toList();
        });
        var service=new ExportDocumentProjectionService(new ExportTableProjectionService(platform));
        var columns=List.of(new ExportColumn("amount","精确原值",ExportColumn.QTY));
        var rows=java.util.stream.IntStream.range(0,401).mapToObj(index->Map.<String,Object>of("amount",
                new BigDecimal("1.00000000000000001").add(BigDecimal.valueOf(index)))).toList();
        var evidence=List.<Map<String,Object>>of(Map.of("amount",new BigDecimal("9999999999999999.00000001")));
        var document=new ExportDocument("实际成本",List.of("原始版本"),List.of(
                new ExportDocument.Section("物料明细",columns,rows),new ExportDocument.Section("独立产出",columns,evidence)));
        var projection=new TableColumnProjection("master.goods.cost.actual.0","view_goods_cost",List.of(
                new TableColumnProjection.Column("platform:"+id,"不能冒充冻结标签",120d,"text",null)));
        var expected=service.project(document,projection,"物料明细","view_goods_cost");
        var collected=new java.util.LinkedHashMap<String,List<Map<String,Object>>>();
        var headers=new java.util.ArrayList<DocumentPageSink.Header>();
        streaming.set(true);
        DocumentPageSink.emitDocument(document,service.stream(new DocumentPageSink.Consumer(){
            public void begin(DocumentPageSink.Header header){headers.add(header);header.sections().forEach(section->collected.put(section.id(),new java.util.ArrayList<>()));}
            public void accept(DocumentPageSink.Page page){collected.get(page.sectionId()).addAll(page.rows());}
        },projection,"物料明细","view_goods_cost"));
        assertThat(headers.getFirst().sections().getFirst().columns()).isEqualTo(expected.sections().getFirst().columns());
        assertThat(collected.get("section-0")).isEqualTo(expected.sections().getFirst().rows());
        assertThat(collected.get("section-1")).isEqualTo(evidence);
        assertThat(headers.getFirst().metadata()).containsExactly("原始版本");
        verify(platform,never()).read(anyString(),any());
    }
    @Test void aDefinitionLostAfterItsHeaderCannotPublishAProjectedPage() {
        var platform=mock(PlatformColumnService.class);UUID id=UUID.randomUUID();
        var definition=new Definition(id,"view_goods_cost","冻结公式","CALCULATED",true,
                new Formula(new Operand(null,"amount",null),List.of()),0,0);
        when(platform.definitionsByIds("view_goods_cost",List.of(id))).thenReturn(List.of(definition),List.of());
        when(platform.evaluateDisplayRows(anyString(),any(),any())).thenReturn(List.of());
        var service=new ExportDocumentProjectionService(new ExportTableProjectionService(platform));
        var destination=mock(DocumentPageSink.Consumer.class);
        var projection=new TableColumnProjection("master.goods.cost.actual.0","view_goods_cost",List.of(new TableColumnProjection.Column("platform:"+id,null,120d,"text",null)));
        var sink=service.stream(destination,projection,"物料明细","view_goods_cost");
        sink.begin(new DocumentPageSink.Header("实际成本",List.of(),List.of(new DocumentPageSink.Section("inputs","物料明细",
                List.of(new ExportColumn("amount","精确原值",ExportColumn.QTY)),true,false)),1));
        assertThatThrownBy(()->sink.accept(new DocumentPageSink.Page("inputs",List.of(Map.of("amount",new BigDecimal("1.00000000000000001"))))))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
        verify(destination,never()).accept(any());
    }
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
