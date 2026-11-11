package com.uten.imp.features.stock;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.readsnapshot.VersionedSummaryPages;
import com.uten.imp.common.report.ReportReadPlan;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.TotaledPageResponse;
import com.uten.imp.features.stock.dto.InstantInventoryRow;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.math.BigDecimal;
import java.sql.Connection;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BiFunction;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** The instant-inventory complete stream shares the master stream's frame contract. */
class InstantInventoryCompleteStreamServiceTest {
    private final ObjectMapper json = new ObjectMapper();
    private final VersionedSummaryPages pages = mock(VersionedSummaryPages.class);
    private final StockQueryService stock = mock(StockQueryService.class);
    private final InstantInventoryCompleteStreamService service =
            new InstantInventoryCompleteStreamService(stock, pages, json);
    private final VersionedSummaryPages.ReadProof proof =
            new VersionedSummaryPages.ReadProof("a".repeat(64), "b".repeat(64), "c".repeat(64));
    private final List<String> plans = new ArrayList<>();

    @BeforeEach void prepare() {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(
                "reader", "unused", List.of(new SimpleGrantedAuthority("stock:view"))));
        TransactionSynchronizationManager.setActualTransactionActive(true);
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);
        TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(Connection.TRANSACTION_REPEATABLE_READ);
        when(pages.readWithProof(any(), any(), any())).thenAnswer(call -> {
            call.getArgument(1, Runnable.class).run();
            BiFunction<VersionedSummaryPages.ReadProof, Runnable, ?> project = call.getArgument(2);
            return proof.snapshot(project.apply(proof, () -> { }));
        });
    }

    @AfterEach void clear() {
        SecurityContextHolder.clearContext();
        TransactionSynchronizationManager.clear();
        plans.clear();
    }

    private static InstantInventoryCompleteRequest request(Integer size, String revisionIgnored) {
        return new InstantInventoryCompleteRequest(new InstantInventoryCompleteRequest.Filter(
                null, null, null, null, null, null, null, null, null, null, null, null, null, null, null),
                1, size, null, null);
    }

    /** Rows are placeholders; the stream owns frame shape, not business mapping. */
    private static InstantInventoryRow row(int index) {
        var row = new InstantInventoryRow(UUID.nameUUIDFromBytes(("row" + index).getBytes()),
                null, null, null, null, "name-" + index, null, null, null, null,
                null, BigDecimal.ZERO, null, null, "code-" + index, null, null,
                null, null, false, false, null, null, false);
        row.setCategoryId(UUID.nameUUIDFromBytes("category".getBytes()));
        return row;
    }

    private void serve(int total) {
        AtomicInteger produced = new AtomicInteger();
        when(stock.instantInventory(any(), anyInt(), anyInt(), isNull(), isNull())).thenAnswer(call -> {
            plans.add(ReportReadPlan.current().includeCount() + "/"
                    + ReportReadPlan.current().includeFacets() + "/"
                    + ReportReadPlan.current().includeTotals());
            int page = call.getArgument(1), size = call.getArgument(2);
            int from = (page - 1) * size;
            int rows = (int) Math.max(0, Math.min(size, total - from));
            var items = new ArrayList<InstantInventoryRow>();
            for (int index = 0; index < rows; index++) items.add(row(produced.getAndIncrement()));
            boolean first = from == 0;
            var pageResponse = new PageResponse<>(items, page, size,
                    first ? total : -1, first ? ReportReadPlan.totalPages(total, size) : -1);
            return first
                    ? new TotaledPageResponse<>(pageResponse, List.of(), Map.of(), Map.of())
                    : pageResponse;
        });
    }

    private List<JsonNode> frames(MockHttpServletResponse response) throws Exception {
        var frames = new ArrayList<JsonNode>();
        for (String line : response.getContentAsString().lines().toList()) frames.add(json.readTree(line));
        return frames;
    }

    /** 2026-11-10 (G): a slow consumer must not spend the data RR transaction's
     * budget. readWithProof closes the data transaction and its publication
     * fence before returning, so only the first frame (the ~1s first screen)
     * may touch the response inside the reader; the other seven page frames
     * and the complete frame must leave after readWithProof returned. */
    @Test void onlyTheFirstFrameLeavesDuringTheDataTransactionTheRestReplayAfterTheFence() throws Exception {
        serve(1050);
        var dataTransactionClosed = new java.util.concurrent.atomic.AtomicBoolean(false);
        org.mockito.Mockito.doAnswer(call -> {
            call.getArgument(1, Runnable.class).run();
            call.getArgument(2, BiFunction.class).apply(proof, (Runnable) () -> { });
            dataTransactionClosed.set(true);
            return proof.snapshot(1050L);
        }).when(pages).readWithProof(any(), any(), any());
        var flushes = new java.util.concurrent.CopyOnWriteArrayList<String>();
        var payload = new java.io.ByteArrayOutputStream();
        var response = org.mockito.Mockito.mock(jakarta.servlet.http.HttpServletResponse.class);
        when(response.getOutputStream()).thenReturn(new jakarta.servlet.ServletOutputStream() {
            @Override public boolean isReady() { return true; }
            @Override public void setWriteListener(jakarta.servlet.WriteListener listener) { }
            @Override public void write(int value) { payload.write(value); }
        });
        org.mockito.Mockito.doAnswer(call -> {
            flushes.add(dataTransactionClosed.get() ? "after" : "during");
            return null;
        }).when(response).flushBuffer();
        service.stream(request(1000, null), null, response);
        // 1050 rows on the progressive plan: 50, 50, 100, 200, 200, 200, 200, 50,
        // then the complete frame — every flush after the first is post-fence.
        assertThat(flushes).containsExactly(
                "during", "after", "after", "after", "after", "after", "after", "after", "after");
        var frames = new ArrayList<JsonNode>();
        for (String line : payload.toString().lines().toList()) frames.add(json.readTree(line));
        assertThat(frames).hasSize(9);
        assertThat(frames.getLast().path("type").asText()).isEqualTo("complete");
        assertThat(frames.getLast().path("total").asLong()).isEqualTo(1050);
    }

    @Test void oneSnapshotFramesTheSharedPlanAndEndsComplete() throws Exception {
        serve(1050);
        var response = new MockHttpServletResponse();
        service.stream(request(1000, null), null, response);
        var frames = frames(response);
        // 50, 50, 100, 200, 200, 200, 200, then 50 more on the aligned 1000 page, + complete.
        assertThat(frames).hasSize(9);
        var sizes = new ArrayList<Integer>();
        var counts = new ArrayList<Integer>();
        for (int index = 0; index < frames.size() - 1; index++) {
            var frame = frames.get(index);
            assertThat(frame.get("type").asText()).isEqualTo("page");
            var value = frame.get("value");
            sizes.add(value.get("size").asInt());
            counts.add(value.get("items").size());
            assertThat(value.get("total").asLong()).isEqualTo(1050);
            assertThat(value.get("readScopeVersion").asText()).isEqualTo(proof.readScopeVersion());
            assertThat(value.get("readSnapshotRevision").asText()).isEqualTo(proof.readSnapshotRevision());
            assertThat(value.get("readDataVersion").asText()).isEqualTo(proof.readDataVersion());
        }
        assertThat(sizes).containsExactly(50, 50, 100, 200, 200, 200, 200, 1000);
        assertThat(counts).containsExactly(50, 50, 100, 200, 200, 200, 200, 50);
        assertThat(frames.getLast().get("type").asText()).isEqualTo("complete");
        assertThat(frames.getLast().get("total").asLong()).isEqualTo(1050);
        // First batch keeps the complete-result metadata; every continuation is rows-only.
        assertThat(plans.getFirst()).isEqualTo("true/true/true");
        assertThat(plans.subList(1, plans.size())).allMatch("false/false/false"::equals);
    }

    @Test void emptyResultIsOnePageFrameAndOneCompleteFrame() throws Exception {
        serve(0);
        var response = new MockHttpServletResponse();
        service.stream(request(1000, null), null, response);
        var frames = frames(response);
        assertThat(frames).hasSize(2);
        assertThat(frames.get(0).get("value").get("items")).isEmpty();
        assertThat(frames.get(1).get("type").asText()).isEqualTo("complete");
        assertThat(frames.get(1).get("total").asLong()).isZero();
    }

    @Test void categoryIdentityIsPreservedInTheExistingSingleScanStream() throws Exception {
        serve(1);
        var response = new MockHttpServletResponse();
        service.stream(request(1000, null), null, response);
        var frames = frames(response);
        assertThat(frames.getFirst().path("value").path("items").get(0).path("categoryId").asText())
                .isEqualTo(UUID.nameUUIDFromBytes("category".getBytes()).toString());
        assertThat(frames.getLast().path("type").asText()).isEqualTo("complete");
    }

    @Test void shortFailingReadWritesOneErrorFrame() throws Exception {
        when(stock.instantInventory(any(), anyInt(), anyInt(), isNull(), isNull()))
                .thenThrow(new ApiException(ErrorCode.PRIMARY_UNAVAILABLE, "读取未完成"));
        var response = new MockHttpServletResponse();
        service.stream(request(1000, null), null, response);
        var frames = frames(response);
        assertThat(frames).hasSize(1);
        assertThat(frames.get(0).get("type").asText()).isEqualTo("error");
        assertThat(frames.get(0).get("code").asText()).isEqualTo("PRIMARY_UNAVAILABLE");
        // A real failure carries one anonymous correlation ref the client keeps
        // in the exception details and quotes with its message.
        assertThat(frames.get(0).path("details").path("correlation").asText())
                .matches("[0-9A-Z]{6}");
    }

    @Test void onlyTheSharedProgressiveRequestSizeIsAccepted() {
        var response = new MockHttpServletResponse();
        assertThatThrownBy(() -> service.stream(request(200, null), null, response))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("完整即时库存读取须从首批开始");
        assertThatThrownBy(() -> service.stream(null, null, response))
                .isInstanceOf(ApiException.class);
    }

    @Test void theProofRequestCarriesTheInventoryContractAndStockScope() throws Exception {
        serve(1);
        var response = new MockHttpServletResponse();
        service.stream(request(1000, null), "f".repeat(64), response);
        var captor = ArgumentCaptor.forClass(VersionedSummaryPages.Request.class);
        verify(pages).readWithProof(captor.capture(), any(), any());
        var request = captor.getValue();
        assertThat(request.domain()).isEqualTo(InstantInventoryCompleteStreamService.READ_DOMAIN);
        assertThat(request.authorizationDomain()).isEqualTo("stock");
        assertThat(request.expectedReadSnapshotRevision()).isEqualTo("f".repeat(64));
        @SuppressWarnings("unchecked")
        Map<String, Object> identity = (Map<String, Object>) request.queryIdentity();
        assertThat(identity.get("contract")).isEqualTo("instant-inventory-complete-v1");
        // 1 row: one page frame plus the complete fence.
        assertThat(frames(response)).hasSize(2);
    }
}
