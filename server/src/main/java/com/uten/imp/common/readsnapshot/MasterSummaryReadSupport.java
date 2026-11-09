package com.uten.imp.common.readsnapshot;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.web.*;
import com.uten.imp.security.CurrentAuthorityGuard;
import org.springframework.stereotype.Service;
import jakarta.persistence.EntityManager;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.io.UncheckedIOException;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/** Complete master summaries share transport proof and validation, never business predicates or DTO calculations. */
@Service
public final class MasterSummaryReadSupport {
    /** The original fixed frame size; existing clients keep requesting it. */
    public static final int READ_BATCH_SIZE = 100;
    /**
     * Request size that selects the progressive frame plan (2026-11-08): 50 rows first,
     * then aligned up to 200 per frame ({@link CompleteReadBatchPlan#PROGRESSIVE}).
     */
    public static final int PROGRESSIVE_REQUEST_SIZE = CompleteReadBatchPlan.MAX_BATCH_SIZE;

    public record Query<F>(F filter, Integer page, Integer size, String sort, String order) {
        public int requestedPage() { return page == null ? 1 : page; }
        public int requestedSize() { return size == null ? READ_BATCH_SIZE : size; }
    }
    public record Payload<T>(List<T> items, int page, int size, long total, int totalPages) {
        public Payload { items = List.copyOf(items); }
    }
    @FunctionalInterface public interface PageLoader<F, T> {
        PageResponse<T> load(F filter, int page, int size, String sort, String order);
    }

    private final VersionedSummaryPages summaries;
    private final ObjectMapper identityJson;
    private final ObjectMapper json;
    private final EntityManager entityManager;

    public MasterSummaryReadSupport(VersionedSummaryPages summaries, ObjectMapper json) {
        this(summaries, json, null);
    }

    @org.springframework.beans.factory.annotation.Autowired
    public MasterSummaryReadSupport(VersionedSummaryPages summaries, ObjectMapper json, EntityManager entityManager) {
        this.summaries = summaries;
        this.json = json;
        this.entityManager = entityManager;
        // Query identity must distinguish original finite monetary values without
        // an intermediate binary float; the owning service still receives F itself.
        identityJson = json.copy().enable(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS);
    }

    public <F, T> void stream(String domain, String authorizationDomain, String permission,
            Query<F> query, String revision, PageLoader<F, T> loader, HttpServletResponse response) throws IOException {
        streamAuthorized(domain, authorizationDomain, "master", query, revision,
                () -> CurrentAuthorityGuard.requireAll(permission), loader, response);
    }

    /** A single response, one counted cursor and one RR data snapshot. Page
     * frames are provisional until the final committed authorization/data fence.
     * Each frame is the exact page the batch plan places at the rows already sent. */
    public <F, T> void streamAuthorized(String domain, String authorizationDomain, String readContract,
            Query<F> query, String revision, Runnable authorize, PageLoader<F, T> loader,
            HttpServletResponse response) throws IOException {
        if (query == null || query.filter() == null || query.requestedPage() != 1
                || (query.requestedSize() != READ_BATCH_SIZE && query.requestedSize() != PROGRESSIVE_REQUEST_SIZE)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "完整资料摘要须从首批开始，保留固定内部批量");
        }
        if (entityManager == null) throw new IllegalStateException("Complete master reads require their shared entity manager");
        var plan = query.requestedSize() == PROGRESSIVE_REQUEST_SIZE
                ? CompleteReadBatchPlan.PROGRESSIVE : CompleteReadBatchPlan.fixed(READ_BATCH_SIZE);
        // The proof identity keeps the original fixed size: both frame plans read one query.
        var request = new VersionedSummaryPages.Request(domain, authorizationDomain, identity(domain, readContract, query),
                "all", 1, READ_BATCH_SIZE, READ_BATCH_SIZE, revision);
        response.setContentType("application/x-ndjson");
        response.setCharacterEncoding("UTF-8");
        response.setHeader("Cache-Control", "no-store");
        response.setHeader("X-Accel-Buffering", "no");
        try {
            var accepted = summaries.readWithProof(request, authorize, (proof, checkpoint) -> {
                response.setHeader("X-Uten-Read-Scope-Version", proof.readScopeVersion());
                try (var cursor = BoundedMasterReadSource.open(entityManager, checkpoint, ignored -> { })) {
                    long seen = 0, expected = -1;
                    while (true) {
                        checkpoint.run();
                        int size = plan.sizeAt(seen), page = plan.pageAt(seen);
                        var value = payload(loader.load(query.filter(), page, size, query.sort(), query.order()), page, size);
                        if (expected < 0) expected = value.total();
                        else if (expected != value.total()) throw incomplete();
                        seen = Math.addExact(seen, value.items().size());
                        if (seen > expected || value.items().isEmpty() && seen < expected) throw incomplete();
                        writeFrame(response, Map.of("type", "page", "value", proof.snapshot(value)));
                        cursor.clearBatch();
                        if (seen == expected) return expected;
                    }
                }
            });
            writeFrame(response, Map.of("type", "complete", "total", accepted.value(),
                    "readScopeVersion", accepted.readScopeVersion(),
                    "readSnapshotRevision", accepted.readSnapshotRevision(), "readDataVersion", accepted.readDataVersion()));
        } catch (UncheckedIOException disconnected) {
            throw disconnected.getCause();
        } catch (RuntimeException failure) {
            ErrorCode code = failure instanceof ApiException api ? api.getCode()
                    : failure instanceof org.springframework.security.access.AccessDeniedException ? ErrorCode.FORBIDDEN
                    : failure instanceof org.springframework.transaction.TransactionTimedOutException
                        || failure instanceof java.util.concurrent.CancellationException ? ErrorCode.PRIMARY_UNAVAILABLE : ErrorCode.INTERNAL;
            if (code == ErrorCode.INTERNAL)
                org.slf4j.LoggerFactory.getLogger(MasterSummaryReadSupport.class).error("Complete master summary read failed for {}", domain, failure);
            String message = failure instanceof ApiException api ? api.getMessage() : code.getDefaultMessage();
            try { writeFrame(response, Map.of("type", "error", "code", code.name(), "message", message)); }
            catch (UncheckedIOException disconnected) { throw disconnected.getCause(); }
        }
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

    public <F, T> VersionedSummaryPages.Snapshot<Payload<T>> read(String domain, String authorizationDomain,
            String permission, Query<F> query, String revision, PageLoader<F, T> loader) {
        return readAuthorized(domain, authorizationDomain, "master", query, revision,
                () -> CurrentAuthorityGuard.requireAll(permission), loader);
    }

    /** Exact business-reference owners retain their existing capability instead of gaining a master grant. */
    public <F, T> VersionedSummaryPages.Snapshot<Payload<T>> readAuthorized(String domain, String authorizationDomain,
            String readContract, Query<F> query, String revision, Runnable authorize, PageLoader<F, T> loader) {
        if (query == null || query.filter() == null || query.requestedPage() < 1
                || query.requestedSize() < 1 || query.requestedSize() > READ_BATCH_SIZE
                || query.requestedPage() > 1 && revision == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请保留首批资料摘要范围和读取版本");
        }
        var request = new VersionedSummaryPages.Request(domain, authorizationDomain, identity(domain, readContract, query),
                "all", query.requestedPage(), query.requestedSize(), READ_BATCH_SIZE, revision);
        return summaries.read(request, authorize, () ->
                payload(loader.load(query.filter(), request.page(), request.size(), query.sort(), query.order()),
                        request.page(), request.size()));
    }

    private <F> Map<String, Object> identity(String domain, String readContract, Query<F> query) {
        Map<String, Object> filter = identityJson.convertValue(query.filter(),
                new TypeReference<LinkedHashMap<String, Object>>() { });
        for (String field : List.of("categoryRootIds", "nullFields")) {
            var value = filter.get(field);
            if (value instanceof List<?> values) {
                filter.put(field, values.stream().map(entry -> entry == null ? null : entry.toString())
                        .sorted(java.util.Comparator.nullsFirst(String::compareTo)).toList());
            }
        }
        Map<String, Object> identity = new LinkedHashMap<>();
        identity.put("contract", domain + "-v1");
        identity.put("readContract", readContract);
        identity.put("filter", filter);
        identity.put("sort", query.sort());
        identity.put("order", query.order());
        identity.put("precisionChoices", BusinessPrecisionContext.choices());
        return identity;
    }

    private static <T> Payload<T> payload(PageResponse<T> result, int page, int size) {
        if (result == null || result.getItems() == null || result.getPage() != page
                || result.getSize() != size || result.getTotal() < 0) throw incomplete();
        long pages = result.getTotal() == 0 ? 0 : 1 + (result.getTotal() - 1) / size;
        long offset = Math.multiplyExact((long) page - 1, size);
        long expected = Math.max(0, Math.min(size, result.getTotal() - offset));
        if (pages != result.getTotalPages() || expected != result.getItems().size()
                || result.getItems().stream().anyMatch(Objects::isNull)) throw incomplete();
        return new Payload<>(result.getItems(), page, size, result.getTotal(), result.getTotalPages());
    }

    private static ApiException incomplete() {
        return new ApiException(ErrorCode.PRIMARY_UNAVAILABLE, "完整资料摘要读取未完成，请刷新后重新读取");
    }
}
