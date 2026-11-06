package com.uten.imp.common.readsnapshot;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.web.*;
import com.uten.imp.security.CurrentAuthorityGuard;
import org.springframework.stereotype.Service;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/** Complete master summaries share transport proof and validation, never business predicates or DTO calculations. */
@Service
public final class MasterSummaryReadSupport {
    public static final int READ_BATCH_SIZE = 100;

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

    public MasterSummaryReadSupport(VersionedSummaryPages summaries, ObjectMapper json) {
        this.summaries = summaries;
        // Query identity must distinguish original finite monetary values without
        // an intermediate binary float; the owning service still receives F itself.
        identityJson = json.copy().enable(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS);
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
