package com.uten.imp.features.master.goods;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.config.Jackson2ObjectMapperAutoConfiguration;
import com.uten.imp.features.master.goods.dto.GoodsFacetPage;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.features.master.goods.dto.GoodsSearchRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** 「组装信息」筛选值在每条货品读取入口都进入同一 GoodsQueryFilter.hasBom，其余条件不丢。 */
class GoodsHasBomRequestBindingTest {

    @Test
    void recordHelpersCarryTheAssemblyFilterAndOnlyItsOwnFacetReleasesIt() {
        UUID category = UUID.randomUUID();
        var legacy = new GoodsQueryFilter(category, null, "开关", null, "S1", null, null, null, null, null, null, null,
                null, null, null, null, null, null, true, true, false, false, null, null, false);
        assertThat(legacy.hasBom()).isNull();
        assertThat(new GoodsQueryFilter(category, null, null, null, null, null, null, null, null, null, null, null,
                null, null, null, null, null, null, null, null, null, null, null, null, null, Map.of(), "c", "u")
                .hasBom()).as("28-argument compatibility constructor").isNull();

        var selected = legacy.withHasBom(true);
        assertThat(selected.hasBom()).isTrue();
        assertThat(selected.withHasBom(null).hasBom()).isNull();
        assertThat(selected.withColumnSearch(Map.of("name", "开关")).hasBom()).isTrue();
        assertThat(selected.withReferences("color", "unit").hasBom()).isTrue();
        assertThat(selected.withReferences("color", "unit").colorRef()).isEqualTo("color");
        assertThat(selected.forFacet("series").hasBom()).isTrue();
        assertThat(selected.forFacet("series").series()).isNull();
        var released = selected.forFacet("hasBom");
        assertThat(released.hasBom()).isNull();
        assertThat(released.series()).isEqualTo("S1");
        assertThat(released.keyword()).isEqualTo("开关");
        assertThat(released.excludeStub()).isTrue();
        assertThat(legacy.withHasBom(false).hasBom()).isFalse();
        assertThat(legacy.withHasBom(false)).isNotEqualTo(legacy.withHasBom(true)).isNotEqualTo(legacy);
    }

    @Test
    void jsonBodiesOfSearchFacetsAndSummariesBindTheAssemblyFilter() throws Exception {
        var json = Jackson2ObjectMapperAutoConfiguration.domainObjectMapper();
        // Flutter sends header values as strings; the typed export job sends booleans.
        assertThat(json.readValue("{\"filter\":{\"hasBom\":\"true\",\"excludeStub\":true}}", GoodsSearchRequest.class)
                .filter().hasBom()).isTrue();
        assertThat(json.readValue("{\"filter\":{\"hasBom\":false}}", GoodsSearchRequest.class)
                .filter().hasBom()).isFalse();
        assertThat(json.readValue("{\"filter\":{\"categoryId\":null}}", GoodsSearchRequest.class)
                .filter().hasBom()).isNull();
    }

    @Test
    @SuppressWarnings("unchecked")
    void queryParametersOfListFacetsAndCandidatesBindTheAssemblyFilter() throws Exception {
        var goods = mock(GoodsService.class);
        when(goods.list(any(), anyInt(), anyInt(), any(), any())).thenReturn(new PageResponse<>(List.of(), 1, 20, 0, 0));
        when(goods.facetValues(any(), any(), any(), anyInt(), anyInt())).thenReturn(new GoodsFacetPage(List.of(), false));
        var controller = new GoodsController(goods, new XlsxExportService(), new WorkbookDownloadService(),
                mock(AuditService.class), mock(SecurityContextCurrentUser.class), mock(AuditDetailViewRecorder.class));
        ReflectionTestUtils.setField(controller, "request", new MockHttpServletRequest());
        MockMvc mvc = MockMvcBuilders.standaloneSetup(controller).build();
        UUID category = UUID.randomUUID();

        mvc.perform(get("/api/master/goods").param("categoryId", category.toString()).param("hasBom", "true")
                .param("excludeStub", "true").param("series", "S1")).andExpect(status().isOk());
        var listed = ArgumentCaptor.forClass(GoodsQueryFilter.class);
        verify(goods).list(listed.capture(), eq(1), eq(20), isNull(), isNull());
        assertThat(listed.getValue().hasBom()).isTrue();
        assertThat(listed.getValue().categoryId()).isEqualTo(category);
        assertThat(listed.getValue().series()).isEqualTo("S1");
        assertThat(listed.getValue().excludeStub()).isTrue();

        mvc.perform(get("/api/master/goods/facets").param("categoryId", category.toString()).param("hasBom", "false"))
                .andExpect(status().isOk());
        var faceted = ArgumentCaptor.forClass(GoodsQueryFilter.class);
        verify(goods).queryFacets(faceted.capture());
        assertThat(faceted.getValue().hasBom()).isFalse();
        assertThat(faceted.getValue().categoryId()).isEqualTo(category);

        mvc.perform(get("/api/master/goods/facet-values").param("field", "hasBom").param("hasBom", "true")
                .param("search", "有")).andExpect(status().isOk());
        var candidates = ArgumentCaptor.forClass(GoodsQueryFilter.class);
        verify(goods).facetValues(candidates.capture(), eq("hasBom"), eq("有"), eq(1), eq(50));
        assertThat(candidates.getValue().hasBom()).isTrue();
    }
}
