package com.uten.imp.common.report;

import com.uten.imp.common.export.*;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.IntStream;
import static org.junit.jupiter.api.Assertions.*;

class ReportExportStreamingTest {
    private static final List<ExportColumn> COLUMNS=List.of(new ExportColumn("id","编号",ExportColumn.TEXT));
    private record Page(List<Map<String,Object>> rows,long total) { }
    private static Page page(int page,int size,int count) {
        int from=Math.min(count,(page-1)*size),to=Math.min(count,from+size);
        return new Page(IntStream.range(from,to).mapToObj(i -> Map.<String,Object>of("id",i)).toList(),-1);
    }
    @Test void streamsOneHundredThousandRowsWithoutReturningAnAccumulatedListOrMetadataQueries() {
        var seen=new AtomicInteger();var batches=new AtomicInteger();
        try(var sink=ExportPageSink.open(payload -> {
            assertTrue(payload.rows().size()<=500);
            for(var row:payload.rows()) assertEquals(seen.getAndIncrement(),row.get("id"));
            batches.incrementAndGet();
        })) {
            var result=ReportQueryKit.paginateAll(100000,(p,size) -> {
                assertEquals(ReportReadPlan.ROWS_ONLY,ReportReadPlan.current());return page(p,size,100000);
            },Page::total,ignored -> COLUMNS,Page::rows);
            assertEquals(100000,result.total());assertTrue(result.rows().isEmpty());
        }
        assertEquals(100000,seen.get());assertEquals(201,batches.get());
        assertEquals(ReportReadPlan.ALL,ReportReadPlan.current());assertNull(ExportPageSink.current());
    }
    @Test void rejectsGrowthPastTheLimitBeforeEmittingTheOffendingPage() {
        var emitted=new AtomicInteger();
        try(var sink=ExportPageSink.open(payload -> emitted.addAndGet(payload.rows().size()))) {
            assertThrows(ApiException.class,() -> ReportQueryKit.paginateAll(700,
                    (p,size) -> page(p,size,800),Page::total,ignored -> COLUMNS,Page::rows));
        }
        assertEquals(500,emitted.get());assertNull(ExportPageSink.current());
    }
    @Test void failedPageDoesNotLeakReadOrOutputScopesAndNeverReturnsPartialSuccess() {
        try(var prior=ReportReadPlan.open(new ReportReadPlan(true,false,true))) {
            assertThrows(IllegalStateException.class,() -> {
                try(var sink=ExportPageSink.open(payload -> {throw new IllegalStateException("disk unavailable");})) {
                    ReportQueryKit.paginateAll(100,(p,size) -> page(p,size,1),Page::total,ignored -> COLUMNS,Page::rows);
                }
            });
            assertEquals(new ReportReadPlan(true,false,true),ReportReadPlan.current());
            assertNull(ExportPageSink.current());
        }
    }
    @Test void emptyAndNaturallyBoundedReportsStillEmitTheirColumns() {
        var batches=new ArrayList<ExportPayload>();
        try(var sink=ExportPageSink.open(batches::add)) {
            var result=ReportQueryKit.paginateAll(100,(p,size) -> page(p,size,0),Page::total,ignored -> COLUMNS,Page::rows);
            assertEquals(0,result.total());assertEquals(COLUMNS,batches.getFirst().columns());
        }
    }
}
