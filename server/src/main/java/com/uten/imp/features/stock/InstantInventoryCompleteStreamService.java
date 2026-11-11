package com.uten.imp.features.stock;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.readsnapshot.CompleteStreamErrors;
import com.uten.imp.common.readsnapshot.VersionedSummaryPages;
import com.uten.imp.common.report.ReportExportCursor;
import com.uten.imp.common.report.ReportReadPlan;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.CompleteReadBatchPlan;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.features.stock.dto.InstantInventoryRow;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 即时库存完整流（2026-11-09）：一个响应里按共享批次计划连续分帧，替代每批一次
 * OFFSET 请求的完整读取。35,763 行实测：每批独立请求合计约 80 秒（OFFSET 越翻越深，
 * 每批重算聚合排序），单扫描流在同一个 RR 快照内一次算完（秒级）。
 *
 * <p>复用既有公共能力，不另造口径：
 * <ul>
 * <li>{@link VersionedSummaryPages#readWithProof} 提供每帧三凭据（readScopeVersion /
 *     readSnapshotRevision / readDataVersion）与读后提交栅栏，帧契约与主档 NDJSON 流一致；
 *     修订域复用 {@code native-facet-instant-stock}——同一批写入方（货品/颜色/单位/仓库/
 *     库存余额与流水/计量）已经通过 fn_mark_summary_read_domain 触发器标记该域，
 *     即时库存行与表头桶的新鲜度语义同源。</li>
 * <li>{@link ReportExportCursor} 在同一个只读 RR 事务内把每批 LIMIT/OFFSET 请求接在
 *     一次有序扫描上：不重复算、不跳行、每批就是它自己页大小下的真实页。</li>
 * <li>首批带 {@link ReportReadPlan#ALL}（行+计数+合计+表头桶，与 GET 首批同口径）；
 *     续批 {@link ReportReadPlan#ROWS_ONLY} 只取行，计数沿用首批在快照内算出的精确值。</li>
 * <li>业务谓词、排序与合计口径仍是 {@link StockQueryService} 唯一维护入口。</li>
 * </ul>
 */
@Service
public class InstantInventoryCompleteStreamService {
    /** 与表头筛选候选同源的即时库存新鲜度域（见类注释）。 */
    static final String READ_DOMAIN = "native-facet-instant-stock";
    private static final String CONTRACT = "instant-inventory-complete-v1";
    private static final org.slf4j.Logger LOG =
            org.slf4j.LoggerFactory.getLogger(InstantInventoryCompleteStreamService.class);

    private final StockQueryService stock;
    private final VersionedSummaryPages summaries;
    private final ObjectMapper json;
    private final ObjectMapper identityJson;

    public InstantInventoryCompleteStreamService(StockQueryService stock, VersionedSummaryPages summaries,
            ObjectMapper json) {
        this.stock = stock;
        this.summaries = summaries;
        this.json = json;
        // Query identity must distinguish original finite monetary values without
        // an intermediate binary float; the owning service still receives the filter.
        identityJson = json.copy().enable(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS);
    }

    public void stream(InstantInventoryCompleteRequest query, String revision, HttpServletResponse response)
            throws IOException {
        if (query == null || query.filter() == null || query.requestedPage() != 1
                || query.requestedSize() != CompleteReadBatchPlan.MAX_BATCH_SIZE) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "完整即时库存读取须从首批开始，保留共享内部批量");
        }
        var filter = toFilter(query.filter());
        var plan = CompleteReadBatchPlan.PROGRESSIVE;
        var request = new VersionedSummaryPages.Request(READ_DOMAIN, "stock",
                identity(query), "all", 1,
                com.uten.imp.common.readsnapshot.MasterSummaryReadSupport.READ_BATCH_SIZE,
                com.uten.imp.common.readsnapshot.MasterSummaryReadSupport.READ_BATCH_SIZE, revision);
        response.setContentType("application/x-ndjson");
        response.setCharacterEncoding("UTF-8");
        response.setHeader("Cache-Control", "no-store");
        response.setHeader("X-Accel-Buffering", "no");
        try {
            var accepted = summaries.readWithProof(request,
                    () -> CurrentAuthorityGuard.requireAll("stock:view"),
                    (proof, checkpoint) -> {
                        response.setHeader("X-Uten-Read-Scope-Version", proof.readScopeVersion());
                        try (var cursor = ReportExportCursor.open()) {
                            long seen = 0, total = -1;
                            while (true) {
                                checkpoint.run();
                                int size = plan.sizeAt(seen), page = plan.pageAt(seen);
                                boolean first = seen == 0;
                                PageResponse<InstantInventoryRow> value;
                                try (var ignored = ReportReadPlan.open(
                                        first ? ReportReadPlan.ALL : ReportReadPlan.ROWS_ONLY)) {
                                    value = stock.instantInventory(filter, page, size, query.sort(), query.order());
                                }
                                if (first) {
                                    total = value.getTotal();
                                    if (total < 0) throw incomplete();
                                } else if (value.getTotal() >= 0 && value.getTotal() != total) {
                                    // One RR snapshot owns every batch; a different count
                                    // means the cursor sequence is not the read's sequence.
                                    throw incomplete();
                                } else if (value.getTotal() < 0) {
                                    value = new PageResponse<>(value.getItems(), page, size, total,
                                            ReportReadPlan.totalPages(total, size));
                                }
                                long expected = Math.max(0, Math.min(size, total - seen));
                                if (value.getItems() == null || value.getItems().size() != expected
                                        || value.getSize() != size || value.getPage() != page) {
                                    throw incomplete();
                                }
                                seen += expected;
                                writeFrame(response, Map.of("type", "page", "value", proof.snapshot(value)));
                                if (seen == total) return total;
                            }
                        }
                    });
            writeFrame(response, Map.of("type", "complete", "total", accepted.value(),
                    "readScopeVersion", accepted.readScopeVersion(),
                    "readSnapshotRevision", accepted.readSnapshotRevision(), "readDataVersion", accepted.readDataVersion()));
        } catch (UncheckedIOException disconnected) {
            throw disconnected.getCause();
        } catch (RuntimeException failure) {
            // One anonymous correlation ref per real failure: the frame carries
            // it in details.correlation and the server log line quotes it.
            var frame = CompleteStreamErrors.errorFrame(LOG, "instant-inventory", failure);
            try { writeFrame(response, frame); }
            catch (UncheckedIOException disconnected) { throw disconnected.getCause(); }
        }
    }

    private static StockQueryService.InstantInventoryFilter toFilter(InstantInventoryCompleteRequest.Filter f) {
        return new StockQueryService.InstantInventoryFilter(f.categoryId(), f.warehouseId(),
                Boolean.TRUE.equals(f.includeDefective()), Boolean.TRUE.equals(f.includeLineSide()),
                f.keyword(), f.owningWarehouse(), f.owningWarehouseNull(), f.colorId(), f.series(),
                f.unitId(), f.attention(), null, false, true,
                Boolean.TRUE.equals(f.includeRelated()), Boolean.TRUE.equals(f.warehouseRelatedOnly()),
                f.dateFrom(), f.dateTo());
    }

    private Map<String, Object> identity(InstantInventoryCompleteRequest query) {
        Map<String, Object> filter = identityJson.convertValue(query.filter(),
                new TypeReference<LinkedHashMap<String, Object>>() { });
        Map<String, Object> identity = new LinkedHashMap<>();
        identity.put("contract", CONTRACT);
        identity.put("filter", filter);
        identity.put("sort", query.sort());
        identity.put("order", query.order());
        return identity;
    }

    private void writeFrame(HttpServletResponse response, Object frame) {
        try {
            byte[] encoded = json.writeValueAsBytes(frame);
            var output = response.getOutputStream();
            output.write(encoded);
            output.write('\n');
            response.flushBuffer();
        } catch (IOException disconnected) { throw new UncheckedIOException(disconnected); }
    }

    private static ApiException incomplete() {
        return new ApiException(ErrorCode.PRIMARY_UNAVAILABLE, "完整即时库存读取未完成，请刷新后重新读取");
    }
}
