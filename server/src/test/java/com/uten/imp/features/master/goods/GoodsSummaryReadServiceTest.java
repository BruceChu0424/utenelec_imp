package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.readsnapshot.VersionedSummaryPages;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.GoodsSearchReadRoutes;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.config.Jackson2ObjectMapperAutoConfiguration;
import com.uten.imp.features.master.goods.dto.GoodsListItem;
import com.uten.imp.features.master.goods.dto.GoodsSearchRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.Supplier;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class GoodsSummaryReadServiceTest {
    private final ObjectMapper json = Jackson2ObjectMapperAutoConfiguration.domainObjectMapper();
    private final GoodsService goods = mock(GoodsService.class);
    private final VersionedSummaryPages summaries = mock(VersionedSummaryPages.class);
    private final List<VersionedSummaryPages.Request> requests = new ArrayList<>();
    private final GoodsSummaryReadService service = new GoodsSummaryReadService(goods, summaries, json);

    @BeforeEach void initialize() {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(
                "reader", "unused", List.of(new SimpleGrantedAuthority("goods:view"))));
        when(summaries.read(any(), any(Runnable.class), any())).thenAnswer(invocation -> {
            requests.add(invocation.getArgument(0));
            invocation.getArgument(1, Runnable.class).run();
            Object value = invocation.getArgument(2, Supplier.class).get();
            return new VersionedSummaryPages.Snapshot<>(value, "a".repeat(64), "b".repeat(64), "c".repeat(64));
        });
    }

    @AfterEach void clear() { SecurityContextHolder.clearContext(); }

    @Test void everyBatchDelegatesTheUnchangedFilterSortAndTypedProjection() {
        var query = query(Map.of("keyword", "中文 %_", "disabledOnly", true,
                "columnSearch", Map.of("stockQty", ">= 1.000001")), 2, 100, "stockQty", "desc");
        var rows = List.of(row("尾批货品", new BigDecimal("9007199254740993.123400")));
        when(goods.list(same(query.filter()), eq(2), eq(100), eq("stockQty"), eq("desc")))
                .thenReturn(new PageResponse<>(rows, 2, 100, 101, 2));
        var result = service.read(query, "b".repeat(64));
        assertThat(result.value().items()).containsExactly(rows.getFirst());
        assertThat(result.value().items().getFirst()).isSameAs(rows.getFirst());
        assertThat(result.value().total()).isEqualTo(101);
        assertThat(result.value().totalPages()).isEqualTo(2);
        var request = requests.getFirst();
        assertThat(request.domain()).isEqualTo("goods-master-list");
        assertThat(request.authorizationDomain()).isEqualTo("master_goods");
        assertThat(request.size()).isEqualTo(100);
        assertThat(request.maxReadSize()).isEqualTo(100);
        assertThat(request.expectedReadSnapshotRevision()).isEqualTo("b".repeat(64));
        verify(goods).list(same(query.filter()), eq(2), eq(100), eq("stockQty"), eq("desc"));
    }

    @Test void unorderedFilterSetsHaveOneIdentityWhileEveryActualFilterAndSortValueRemainsBound() throws Exception {
        UUID first = UUID.randomUUID(), second = UUID.randomUUID();
        var columns = new java.util.LinkedHashMap<String, String>();
        columns.put("name", "中文"); columns.put("model", "M3");
        var reversedColumns = new java.util.LinkedHashMap<String, String>();
        reversedColumns.put("model", "M3"); reversedColumns.put("name", "中文");
        var left = query(Map.of("categoryRootIds", List.of(first, second), "nullFields", List.of("series", "model"),
                "keyword", "中文", "disabledOnly", true, "columnSearch", columns), 1, 100, null, null);
        var right = query(Map.of("categoryRootIds", List.of(second, first), "nullFields", List.of("model", "series"),
                "keyword", "中文", "disabledOnly", true, "columnSearch", reversedColumns), 1, 100, null, null);
        when(goods.list(any(), eq(1), eq(100), isNull(), isNull()))
                .thenReturn(new PageResponse<>(List.of(), 1, 100, 0, 0));
        service.read(left, null);
        service.read(right, null);
        assertThat(json.<com.fasterxml.jackson.databind.JsonNode>valueToTree(requests.get(0).queryIdentity()))
                .isEqualTo(json.valueToTree(requests.get(1).queryIdentity()));
        var canonical = json.copy().enable(com.fasterxml.jackson.databind.SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS);
        assertThat(canonical.writeValueAsString(requests.get(0).queryIdentity()))
                .isEqualTo(canonical.writeValueAsString(requests.get(1).queryIdentity()));
        service.read(query(Map.of("keyword", "另一个条件"), 1, 100, null, null), null);
        assertThat(json.<com.fasterxml.jackson.databind.JsonNode>valueToTree(requests.get(2).queryIdentity()))
                .isNotEqualTo(json.valueToTree(requests.getFirst().queryIdentity()));
    }

    @Test void nextBatchesRequireTheInitialRevisionAndTheReadCapDoesNotChange() {
        for (var query : List.of(query(Map.of(), 2, 100, null, null),
                query(Map.of(), 1, 101, null, null), query(Map.of(), 0, 100, null, null),
                query(Map.of(), 1, 0, null, null))) {
            assertThatThrownBy(() -> service.read(query, null))
                    .isInstanceOfSatisfying(ApiException.class,
                            failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        }
        verifyNoInteractions(goods);
        assertThat(requests).isEmpty();
    }

    @Test void missingRowsOrInconsistentNormalizedMetadataCannotClaimACompleteSnapshot() {
        var query = query(Map.of(), 1, 100, null, null);
        for (var source : List.of(new PageResponse<GoodsListItem>(List.of(), 1, 100, 2414, 25),
                new PageResponse<GoodsListItem>(List.of(), 1, 500, 0, 0),
                new PageResponse<GoodsListItem>(List.of(), 1, 100, 0, 1))) {
            when(goods.list(any(), eq(1), eq(100), isNull(), isNull())).thenReturn(source);
            assertThatThrownBy(() -> service.read(query, null))
                    .isInstanceOfSatisfying(ApiException.class,
                            failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.PRIMARY_UNAVAILABLE));
        }
    }

    @Test void originalDtoPrecisionChineseAndWritableFieldsSurviveAFlatUniqueProofEnvelope() throws Exception {
        var query = query(Map.of(), 1, 100, null, null);
        var row = row("中文尾项", new BigDecimal("9007199254740993.123400"));
        row.setWritable(false);
        row.setCurrencyCode("USD");
        when(goods.list(any(), eq(1), eq(100), isNull(), isNull()))
                .thenReturn(new PageResponse<>(List.of(row), 1, 100, 1, 1));
        String encoded = json.writeValueAsString(service.read(query, null));
        var decoded = json.readTree(encoded);
        assertThat(decoded.has("value")).isFalse();
        assertThat(decoded.path("items").get(0).path("priceDisplayText").asText())
                .isEqualTo("9007199254740993.1234");
        assertThat(encoded).contains("9007199254740993.123400", "中文尾项");
        assertThat(decoded.path("items").get(0).path("currencyCode").asText()).isEqualTo("USD");
        assertThat(decoded.path("items").get(0).path("writable").asBoolean()).isFalse();
        for (String field : List.of("readScopeVersion", "readSnapshotRevision", "readDataVersion"))
            assertThat(encoded.split("\"" + field + "\"", -1)).hasSize(2);
    }

    @Test void freshAuthorizationRemainsRequiredAndOnlyTheExactSummaryBodyIsReadOnly() {
        SecurityContextHolder.clearContext();
        assertThatThrownBy(() -> service.read(query(Map.of(), 1, 100, null, null), null))
                .isInstanceOfSatisfying(ApiException.class,
                        failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
        verifyNoInteractions(goods);
        assertThat(GoodsSearchReadRoutes.matches("POST", "/api/master/goods/summaries")).isTrue();
        for (String route : List.of("/api/master/goods/summaries/save", "/api/master/goods/export",
                "/api/business-references/goods/summaries"))
            assertThat(GoodsSearchReadRoutes.matches("POST", route)).isFalse();
        assertThat(GoodsSearchReadRoutes.matches("DELETE", "/api/master/goods/summaries")).isFalse();
    }

    private GoodsSearchRequest query(Map<String, ?> filter, int page, int size, String sort, String order) {
        var payload = new java.util.LinkedHashMap<String, Object>();
        payload.put("filter", filter); payload.put("page", page); payload.put("size", size);
        payload.put("sort", sort); payload.put("order", order);
        return json.convertValue(payload, GoodsSearchRequest.class);
    }

    private GoodsListItem row(String name, BigDecimal price) {
        return new GoodsListItem(UUID.randomUUID(), "G-001", name, null, null, price, null,
                "正常", null, null, null, "原始标识", null, null, null, null, null, null, null,
                null, null, null, null, null, UUID.randomUUID(), false, new BigDecimal("1.000001"),
                null, null, null, null, null, null, null, 7L, "ORDER", null, null, false, null, null);
    }
}
