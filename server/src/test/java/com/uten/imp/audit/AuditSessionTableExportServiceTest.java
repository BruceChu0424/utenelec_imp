package com.uten.imp.audit;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPageSink;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.*;
import java.util.concurrent.CancellationException;
import java.util.stream.IntStream;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class AuditSessionTableExportServiceTest {
    private final AuditSessionQueryService query=mock(AuditSessionQueryService.class);
    private final AuditSessionTableExportService service=new AuditSessionTableExportService(query);
    private final UUID actor=UUID.randomUUID();
    private final LocalDate from=LocalDate.of(2026,9,1),to=from.plusDays(1);
    @Test void exportUsesVisibleSessionSchemaAndFreezesOneSnapshotAcrossAllPages() {
        var row=mock(AuditSessionRow.class);
        UUID sessionId=UUID.randomUUID();when(row.sessionId()).thenReturn(sessionId);
        when(row.actorDisplay()).thenReturn("员工");when(row.operationCount()).thenReturn(4L);
        when(query.sessionsForExport(actor,from,to,1,100,99L,null)).thenReturn(new AuditSessionPageResponse(Collections.nCopies(100,row),1,100,101,2,99));
        when(query.sessionsForExport(actor,from,to,2,100,99L,101L)).thenReturn(new AuditSessionPageResponse(List.of(row),2,100,101,2,99));
        var result=service.export(actor,from,to,99L,1000);
        assertThat(result.columns()).extracting(ExportColumn::key).containsExactly("actor","login","status","device","operations","failures","postLogout","logout","credential");
        assertThat(result.rows()).hasSize(101);
        assertThat(result.rows().getFirst()).containsEntry("operations",4L).containsEntry("actor","员工");
        assertThat(result.rows().getFirst()).containsEntry("sessionId",sessionId);
        verify(query).sessionsForExport(actor,from,to,2,100,99L,101L);
    }
    @Test void aComplete1201RowResultIgnoresTheOldConfiguredLimitAndCountsOnlyItsFirstBatch() {
        when(query.sessionsForExport(eq(actor),eq(from),eq(to),anyInt(),eq(100),eq(99L),nullable(Long.class)))
                .thenAnswer(call->{
                    int page=call.getArgument(3);
                    assertThat(call.<Long>getArgument(6)).isEqualTo(page==1?null:1201L);
                    return response(page,1201,99);
                });
        var result=service.export(actor,from,to,99L,10);
        assertThat(result.total()).isEqualTo(1201);
        assertThat(result.rows()).extracting(row->row.get("sessionId"))
                .containsExactlyElementsOf(IntStream.range(0,1201).mapToObj(index->new UUID(1,index)).toList());
        assertThat(result.rows().getLast()).containsEntry("actor","员工-1200").containsEntry("operations",4L);
        verify(query,times(13)).sessionsForExport(eq(actor),eq(from),eq(to),anyInt(),eq(100),eq(99L),nullable(Long.class));
    }

    @Test void anIncompleteFirstBatchFailsBeforeRequestingAnyContinuation() {
        when(query.sessionsForExport(actor,from,to,1,100,99L,null)).thenReturn(new AuditSessionPageResponse(List.of(),1,100,21,2,99));
        assertThatThrownBy(()->service.export(actor,from,to,99L,10)).isInstanceOfSatisfying(ApiException.class,
                error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT)).hasMessageContaining("未完整返回");
        verify(query,times(1)).sessionsForExport(eq(actor),eq(from),eq(to),anyInt(),anyInt(),nullable(Long.class),nullable(Long.class));
    }

    @Test void snapshotAndTotalDriftRejectOtherwiseValidContinuationPages() {
        for(boolean snapshotDrift:List.of(false,true)) {
            reset(query);
            when(query.sessionsForExport(actor,from,to,1,100,99L,null)).thenReturn(response(1,101,99));
            var stable=response(2,101,99);
            when(query.sessionsForExport(actor,from,to,2,100,99L,101L)).thenReturn(new AuditSessionPageResponse(
                    stable.items(),2,100,snapshotDrift?101:102,2,snapshotDrift?100:99));
            assertThatThrownBy(()->service.export(actor,from,to,99L,10)).isInstanceOfSatisfying(ApiException.class,
                    error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT)).hasMessageContaining("范围已变化");
            verify(query).sessionsForExport(actor,from,to,2,100,99L,101L);
        }
    }

    @Test void pageCoordinatesMissingRowsAndShortTailNeverPublishACompleteResult() {
        var last=response(2,101,99);
        var invalid=List.of(new AuditSessionPageResponse(last.items(),1,100,101,2,99),
                new AuditSessionPageResponse(last.items(),2,99,101,2,99),
                new AuditSessionPageResponse(last.items(),2,100,101,1,99),
                new AuditSessionPageResponse(List.of(),2,100,101,2,99));
        for(var page:invalid) {
            reset(query);
            when(query.sessionsForExport(actor,from,to,1,100,99L,null)).thenReturn(response(1,101,99));
            when(query.sessionsForExport(actor,from,to,2,100,99L,101L)).thenReturn(page);
            assertThatThrownBy(()->service.export(actor,from,to,99L,10)).isInstanceOf(ApiException.class).hasMessageContaining("未完整返回");
        }
    }

    @Test void cancellationAfterAStreamedBatchStopsReadsAndDoesNotReturnPartialSuccess() {
        when(query.sessionsForExport(actor,from,to,1,100,99L,null)).thenReturn(response(1,1201,99));
        try(var sink=ExportPageSink.open(page->{assertThat(page.rows()).hasSize(100);Thread.currentThread().interrupt();})) {
            try{assertThatThrownBy(()->service.export(actor,from,to,99L,10)).isInstanceOf(CancellationException.class);}
            finally{Thread.interrupted();}
        }
        assertThat(ExportPageSink.current()).isNull();
        verify(query,times(1)).sessionsForExport(eq(actor),eq(from),eq(to),anyInt(),anyInt(),nullable(Long.class),nullable(Long.class));
    }

    @Test void theFirstAuthoritativeSnapshotIsFrozenEvenWhenTheCallerDidNotSupplyOne() {
        when(query.sessionsForExport(actor,from,to,1,100,null,null)).thenReturn(response(1,101,99));
        when(query.sessionsForExport(actor,from,to,2,100,99L,101L)).thenReturn(response(2,101,99));
        assertThat(service.export(actor,from,to,null,10).rows()).hasSize(101);
        verify(query).sessionsForExport(actor,from,to,2,100,99L,101L);
    }

    private AuditSessionPageResponse response(int page,int total,long snapshot) {
        var at=OffsetDateTime.parse("2026-09-01T10:00:00+08:00");
        var rows=IntStream.range((page-1)*100,Math.min(page*100,total)).mapToObj(index->new AuditSessionRow(
                new UUID(1,index),actor,"fixture","员工-"+index,null,null,"login","登录",at,at,at,null,
                "ACTIVE","有效",4,4,4,0,0,null,"本机","windows",null,null,null,"ACTIVE","有效",false,snapshot)).toList();
        return new AuditSessionPageResponse(rows,page,100,total,(total+99)/100,snapshot);
    }
}
