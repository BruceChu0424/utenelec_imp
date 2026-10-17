package com.uten.imp.features.master.goods.history;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.http.MediaType;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.authorization.method.AuthorizationManagerBeforeMethodInterceptor;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

class GoodsOperationHistoryControllerTest {
    private final GoodsOperationHistoryService service = mock(GoodsOperationHistoryService.class);
    private final GoodsOperationHistoryController controller = new GoodsOperationHistoryController(service);
    private final MockMvc mvc = MockMvcBuilders.standaloneSetup(controller).build();
    private final GoodsOperationHistoryService.History empty =
            new GoodsOperationHistoryService.History(List.of(), List.of());

    @AfterEach
    void clearIdentity() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void bothCommandsRequireAnExplicitNonnegativeVersionBeforeCallingTheService() throws Exception {
        UUID id = UUID.randomUUID();
        for (String action : List.of("undo", "redo")) {
            for (String body : List.of("{}", "{\"expectedVersion\":null}", "{\"expectedVersion\":-1}")) {
                mvc.perform(post("/api/master/goods/history/{id}/{action}", id, action)
                                .contentType(MediaType.APPLICATION_JSON).content(body))
                        .andExpect(status().isBadRequest());
            }
        }
        verifyNoInteractions(service);
    }

    @Test
    void commandBindingPreservesTheChosenOperationAndItsExactVersion() throws Exception {
        UUID id = UUID.randomUUID();
        when(service.undo(id, 7)).thenReturn(empty);
        when(service.redo(id, 8)).thenReturn(empty);

        mvc.perform(post("/api/master/goods/history/{id}/undo", id)
                        .contentType(MediaType.APPLICATION_JSON).content("{\"expectedVersion\":7}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.entries").isArray());
        mvc.perform(post("/api/master/goods/history/{id}/redo", id)
                        .contentType(MediaType.APPLICATION_JSON).content("{\"expectedVersion\":8}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.events").isArray());

        verify(service).undo(id, 7);
        verify(service).redo(id, 8);
        verifyNoMoreInteractions(service);
    }

    @Test
    void listReturnsOnlyPublicSummaryAndCapabilities() throws Exception {
        UUID id = UUID.randomUUID();
        var entry = new GoodsOperationHistoryService.Entry(id, "GOODS_DELETE", "删除货品", "G001 连接件",
                OffsetDateTime.parse("2026-10-16T08:00:00Z"), "APPLIED", 3, 2, true, false, null);
        when(service.list()).thenReturn(new GoodsOperationHistoryService.History(List.of(entry), List.of()));

        String response = mvc.perform(get("/api/master/goods/history"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.entries[0].id").value(id.toString()))
                .andExpect(jsonPath("$.entries[0].summary").value("G001 连接件"))
                .andExpect(jsonPath("$.entries[0].canUndo").value(true))
                .andReturn().getResponse().getContentAsString();
        assertThat(response).doesNotContain("before_row", "after_row", "expected_row", "price", "discount");
    }

    @Test
    void methodSecurityRejectsAViewerWithoutGoodsAccessBeforeReadingHistory() {
        ProxyFactory factory = new ProxyFactory(controller);
        factory.setProxyTargetClass(true);
        factory.addAdvisor(AuthorizationManagerBeforeMethodInterceptor.preAuthorize());
        GoodsOperationHistoryController secured = (GoodsOperationHistoryController) factory.getProxy();
        SecurityContextHolder.getContext().setAuthentication(
                new TestingAuthenticationToken("operator", "unused", "goods:edit"));

        assertThatThrownBy(secured::list).isInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(service);

        when(service.list()).thenReturn(empty);
        SecurityContextHolder.getContext().setAuthentication(
                new TestingAuthenticationToken("operator", "unused", "goods:view"));
        assertThat(secured.list()).isSameAs(empty);
        verify(service).list();
    }
}
