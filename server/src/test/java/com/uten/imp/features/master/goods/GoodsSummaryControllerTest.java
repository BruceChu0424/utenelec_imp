package com.uten.imp.features.master.goods;

import com.uten.imp.common.readsnapshot.VersionedSummaryPages;
import com.uten.imp.config.Jackson2ObjectMapperAutoConfiguration;
import com.uten.imp.features.master.goods.dto.GoodsSearchRequest;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.http.converter.json.MappingJackson2HttpMessageConverter;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.util.List;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

@SuppressWarnings("removal") // The owning application currently pins its Jackson 2 converter.
class GoodsSummaryControllerTest {
    @Test void exactBodyEndpointKeepsTypedRowsAndTheAcceptedAuthorizationHeader() throws Exception {
        var service = mock(GoodsSummaryReadService.class);
        var payload = new GoodsSummaryReadService.Payload(List.of(), 1, 100, 0, 0);
        when(service.read(any(GoodsSearchRequest.class), eq("b".repeat(64))))
                .thenReturn(new VersionedSummaryPages.Snapshot<>(payload, "a".repeat(64), "b".repeat(64), "c".repeat(64)));
        var json = Jackson2ObjectMapperAutoConfiguration.domainObjectMapper();
        var mvc = MockMvcBuilders.standaloneSetup(new GoodsSummaryController(service))
                .setMessageConverters(new MappingJackson2HttpMessageConverter(json)).build();
        var response = mvc.perform(post("/api/master/goods/summaries")
                .param("readSnapshotRevision", "b".repeat(64))
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"filter\":{\"keyword\":\"中文\",\"disabledOnly\":true},\"page\":1,\"size\":100}"))
                .andReturn().getResponse();
        assertThat(response.getStatus()).isEqualTo(200);
        assertThat(response.getHeader("X-Uten-Read-Scope-Version")).isEqualTo("a".repeat(64));
        var body = json.readTree(response.getContentAsString(java.nio.charset.StandardCharsets.UTF_8));
        assertThat(body.path("size").asInt()).isEqualTo(100);
        assertThat(body.path("readSnapshotRevision").asText()).isEqualTo("b".repeat(64));
        assertThat(body.has("value")).isFalse();
        verify(service).read(argThat(query -> "中文".equals(query.filter().keyword())
                && Boolean.TRUE.equals(query.filter().disabledOnly()) && query.requestedSize() == 100),
                eq("b".repeat(64)));
        var method = GoodsSummaryController.class.getMethod("read", GoodsSearchRequest.class, String.class,
                jakarta.servlet.http.HttpServletRequest.class, jakarta.servlet.http.HttpServletResponse.class);
        assertThat(method.getAnnotation(PreAuthorize.class).value()).isEqualTo("hasAuthority('goods:view')");
        assertThat(java.lang.reflect.Modifier.isFinal(GoodsSummaryController.class.getModifiers())).isFalse();
    }
}
