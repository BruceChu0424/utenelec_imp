package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.common.export.ExportPageSink;
import com.uten.imp.common.export.LegacyExportBudget;
import com.uten.imp.common.export.XlsxExportService;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.io.ByteArrayInputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CancellationException;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class WarehouseTaskCenterExportServiceTest {
    private final WarehouseOutboundTaskCenterQueryService outbound = mock(WarehouseOutboundTaskCenterQueryService.class);
    private final WarehouseInboundTaskCenterQueryService inbound = mock(WarehouseInboundTaskCenterQueryService.class);
    private final WarehouseTaskCenterExportService service = new WarehouseTaskCenterExportService(outbound, inbound);
    private final WarehouseTaskCenterContracts.Filter filter = new WarehouseTaskCenterContracts.Filter("ALL", null,
            "frozen-filter", null, null, null, UUID.randomUUID(), 9, 20, "billNo", "desc",
            WarehouseTaskCenterContracts.TaskView.HISTORY, Map.of("goodsName", "原货品"));

    @AfterEach void clearInterrupt() { Thread.interrupted(); }

    @Test void bothDirectionsDownloadEveryRowBeyondFiveHundredAsOneWorkbook() throws Exception {
        for (boolean direction : List.of(true, false)) {
            source(direction, 1201);
            try (var operation = new LegacyExportBudget(1).open()) {
                var built = new XlsxExportService().buildSource(() -> direction ? service.outbound(filter) : service.inbound(filter), null, null);
                assertThat(built.payload().total()).isEqualTo(1201);
                assertThat(built.payload().rows()).isEmpty();
                try (var workbook = new XSSFWorkbook(new ByteArrayInputStream(built.bytes()))) {
                    var sheet = workbook.getSheetAt(0);
                    assertThat(sheet.getLastRowNum()).isEqualTo(1201);
                    assertThat(sheet.getRow(1).getCell(1).getStringCellValue()).isEqualTo("bill-1");
                    assertThat(sheet.getRow(1201).getCell(1).getStringCellValue()).isEqualTo("bill-1201");
                }
            }
        }
    }

    @Test void streamingKeepsOnlyOneHundredRowsAndContinuesPastTheOldTwoThousandPageCutoff() {
        source(true, 200001);
        var batches = new AtomicInteger();
        var received = new AtomicInteger();
        try (var sink = ExportPageSink.open(page -> {
            assertThat(page.rows()).hasSizeLessThanOrEqualTo(100);
            received.addAndGet(page.rows().size()); batches.incrementAndGet();
        })) {
            var result = service.outbound(filter);
            assertThat(result.total()).isEqualTo(200001);
            assertThat(result.rows()).isEmpty();
        }
        assertThat(received).hasValue(200001);
        assertThat(batches).hasValue(2001);
    }

    @Test void emptyResultHasOneValidEmptyBatchAndZeroAuthoritativeTotal() {
        source(false, 0);
        var batches = new ArrayList<Integer>();
        try (var sink = ExportPageSink.open(page -> batches.add(page.rows().size()))) {
            var result = service.inbound(filter);
            assertThat(result.total()).isZero();
            assertThat(result.rows()).isEmpty();
        }
        assertThat(batches).containsExactly(0);
    }

    @Test void partialOrChangedSourcesCannotPublishACompleteFile() {
        for (String violation : List.of("short", "total", "page", "size", "unknown")) {
            doAnswer(call -> {
                var request = (WarehouseTaskCenterContracts.Filter) call.getArgument(0);
                if (request.page() == 1 && !violation.equals("unknown")) return page(request, 201);
                return new WarehouseTaskCenterContracts.Page(violation.equals("short") ? List.of(row(101)) : page(request, 201).items(),
                        violation.equals("page") ? 1 : request.page(), violation.equals("size") ? 20 : 100,
                        violation.equals("unknown") ? -1 : violation.equals("total") ? 202 : 201, 3, null, false);
            }).when(outbound).list(any(), eq(false));
            assertThatThrownBy(() -> new XlsxExportService().buildSource(() -> service.outbound(filter), null, null))
                    .isInstanceOf(IllegalStateException.class);
        }
    }

    @Test void interruptionStopsBeforeAnotherReadAndDoesNotReplayARead() {
        source(false, 1201);
        try (var sink = ExportPageSink.open(page -> Thread.currentThread().interrupt())) {
            assertThatThrownBy(() -> service.inbound(filter)).isInstanceOf(CancellationException.class);
        } finally { Thread.interrupted(); }
        verify(inbound, times(1)).list(any(), eq(false));
    }

    @Test void completeSourceOwnsOneReadOnlyRepeatableReadTransaction() {
        var transaction = WarehouseTaskCenterExportService.class.getAnnotation(Transactional.class);
        assertThat(transaction.readOnly()).isTrue();
        assertThat(transaction.isolation()).isEqualTo(Isolation.REPEATABLE_READ);
    }

    private void source(boolean direction, int count) {
        if (direction) when(outbound.list(any(), eq(false))).thenAnswer(call -> page(call.getArgument(0), count));
        else when(inbound.list(any(), eq(false))).thenAnswer(call -> page(call.getArgument(0), count));
    }

    private WarehouseTaskCenterContracts.Page page(WarehouseTaskCenterContracts.Filter request, int count) {
        assertThat(request.size()).isEqualTo(100);
        assertThat(request.keyword()).isEqualTo(filter.keyword());
        assertThat(request.view()).isEqualTo(filter.view());
        assertThat(request.scopeWarehouseId()).isEqualTo(filter.scopeWarehouseId());
        assertThat(request.columnSearch()).isEqualTo(filter.columnSearch());
        assertThat(request.sort()).isEqualTo(filter.sort());
        assertThat(request.order()).isEqualTo(filter.order());
        var rows = IntStream.range((request.page() - 1) * 100, Math.min(count, request.page() * 100))
                .mapToObj(index -> row(index + 1)).toList();
        return new WarehouseTaskCenterContracts.Page(rows, request.page(), 100, count, (count + 99) / 100, null, false);
    }

    private static WarehouseTaskCenterContracts.Row row(int number) {
        UUID id = new UUID(1, number);
        return new WarehouseTaskCenterContracts.Row("PURCHASE:RECEIPT:" + id, id, "PURCHASE", "RECEIPT", "bill-" + number,
                null, null, null, null, null, 1, "DONE", "已入库", "neutral", "NONE", null, false, Map.of());
    }
}
