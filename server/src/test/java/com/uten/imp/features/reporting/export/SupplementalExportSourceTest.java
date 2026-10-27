package com.uten.imp.features.reporting.export;

import com.uten.imp.application.port.ExportLimitPort;
import com.uten.imp.audit.*;
import com.uten.imp.common.export.*;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.goods.costing.GoodsActualCostSnapshotService;
import com.uten.imp.security.*;
import org.junit.jupiter.api.*;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class SupplementalExportSourceTest {
    private static final UUID GOODS=UUID.randomUUID(),ACTOR=UUID.randomUUID();
    @AfterEach void clear(){SecurityContextHolder.clearContext();}
    private AuthUser user(Set<String> permissions){return new AuthUser(ACTOR,UUID.randomUUID(),"fixture",permissions,false,true,false);}
    private void bind(Set<String> permissions){var user=user(permissions);SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));}
    private ReportExportRequest request(String domain,String report,Map<String,String> parameters){return new ReportExportRequest(UUID.randomUUID(),domain,report,parameters,null,null,null);}
    @Test void auditModesReuseTheirOriginalAuthoritiesAndTypedFilters() {
        var activity=mock(AuditQueryService.class);var sessions=mock(AuditSessionTableExportService.class);var limits=mock(ExportLimitPort.class);
        when(limits.exportMaxRows()).thenReturn(9876);bind(Set.of("audit_log:view","audit_log:export"));
        var source=new AuditReportExportSource(activity,sessions,limits);
        var parameters=Map.of("actorId",ACTOR.toString(),"dateFrom","2026-10-01","dateTo","2026-10-26","snapshotId","9007199254740993","activityOnly","false");
        var query=request("audit","activity",parameters);var criteria=AuditReportExportSource.criteria(query);
        assertEquals(ACTOR,criteria.actorId());assertFalse(criteria.activityOnly());assertEquals(9007199254740993L,criteria.snapshotId());
        source.read(query);verify(activity).export(criteria,9876);
        source.read(request("audit","sessions",parameters));verify(sessions).export(ACTOR,criteria.dateFrom(),criteria.dateTo(),criteria.snapshotId(),9876);
        assertDoesNotThrow(()->AuditReportExportSource.authorize(user(Set.of("audit_log:view","audit_log:export"))));
        assertThrows(ApiException.class,()->AuditReportExportSource.authorize(user(Set.of("audit_log:view"))));
    }
    @Test void malformedFiltersNeverReachTheOriginalAuditReaders() {
        for(var parameter:List.of(Map.of("actorId","invalid"),Map.of("dateFrom","invalid"),Map.of("snapshotId","1.2"),
                Map.of("activityOnly","not-a-boolean"),Map.of("unknownFilter","1")))
            assertThrows(ApiException.class,()->AuditReportExportSource.criteria(request("audit","activity",parameter)));
    }
    @Test void actualCostKeepsItsOriginalThreePermissionsAndExactInspectedDigest() {
        var query=request("goods_actual_cost","snapshot",Map.of("goodsId",GOODS.toString(),"expectedDigest","a".repeat(64),"from","2026-10-01"));
        var input=ActualCostReportExportSource.input(query);
        assertEquals(GOODS,input.query().goodsId());assertEquals("a".repeat(64),input.expectedDigest());
        assertDoesNotThrow(()->ActualCostReportExportSource.authorize(user(Set.of("goods:view","goods:cost:view","goods:cost:export"))));
        assertThrows(ApiException.class,()->ActualCostReportExportSource.authorize(user(Set.of("goods:cost:view","goods:cost:export"))));
        assertThrows(ApiException.class,()->ActualCostReportExportSource.input(request("goods_actual_cost","snapshot",Map.of("goodsId",GOODS.toString(),"expectedDigest","bad"))));
        assertThrows(ApiException.class,()->ActualCostReportExportSource.input(request("goods_actual_cost","snapshot",Map.of("goodsId",GOODS.toString(),"expectedDigest","a".repeat(64),"from","2026-10-26","to","2026-10-01"))));
    }
    @Test void actualCostUsesTheSectionContractAndDoesNotMergeIndependentEvidence() {
        bind(Set.of("goods:view","goods:cost:view","goods:cost:export"));
        var actual=mock(GoodsActualCostSnapshotService.class);
        var projections=new ExportDocumentProjectionService(new ExportTableProjectionService(mock(com.uten.imp.common.platformcolumns.PlatformColumnService.class)));
        var source=new ActualCostReportExportSource(actual,projections);
        var amount=new ExportColumn("amount","原始金额",ExportColumn.QTY);var note=new ExportColumn("note","来源原文",ExportColumn.TEXT);
        var untouched=Map.<String,Object>of("amount","1234567890123456.00000001","note","保留原始来源");
        doAnswer(call->{
            assertEquals(ExportDocument.MAX_SECTION_ROWS,call.getArgument(2,Integer.class).intValue());
            var sink=DocumentPageSink.current();
            sink.begin(new DocumentPageSink.Header("实际成本",List.of("固定digest"),List.of(
                    new DocumentPageSink.Section("inputs","物料及费用来源",List.of(amount,note),true,false),
                    new DocumentPageSink.Section("objects","成本对象",List.of(amount,note),false,false)),1));
            sink.accept(new DocumentPageSink.Page("inputs",List.of(untouched)));sink.accept(new DocumentPageSink.Page("objects",List.of(untouched)));return null;
        }).when(actual).streamExport(any(),anyString(),anyInt());
        var projection=new TableColumnProjection("master.goods.cost.actual.2","view_goods_cost",List.of(new TableColumnProjection.Column("amount","不替换规范表头",120d,"text",null)));
        var request=new ReportExportRequest(UUID.randomUUID(),"goods_actual_cost","snapshot",Map.of("goodsId",GOODS.toString(),"expectedDigest","a".repeat(64)),null,null,projection,"pdf");
        var headers=new ArrayList<DocumentPageSink.Header>();var pages=new ArrayList<DocumentPageSink.Page>();
        try(var sink=DocumentPageSink.open(new DocumentPageSink.Consumer(){@Override public void begin(DocumentPageSink.Header h){headers.add(h);}@Override public void accept(DocumentPageSink.Page p){pages.add(p);}})){
            source.readDocument(request);
        }
        assertEquals(2,headers.getFirst().sections().getFirst().columns().size());
        assertEquals(List.of(new ExportColumn("amount","原始金额",ExportColumn.QTY,120d,null,null)),headers.getFirst().sections().get(1).columns());
        assertEquals(untouched,pages.getFirst().rows().getFirst());
        assertEquals("1234567890123456.00000001",pages.get(1).rows().getFirst().get("amount"));
        verify(actual).streamExport(ActualCostReportExportSource.input(request).query(),"a".repeat(64),ExportDocument.MAX_SECTION_ROWS);
    }
}
