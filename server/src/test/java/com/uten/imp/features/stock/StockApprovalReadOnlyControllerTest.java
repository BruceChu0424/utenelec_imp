package com.uten.imp.features.stock;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.stock.dto.StockDocDetail;
import com.uten.imp.features.stock.dto.StockDocOutboundReview;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.authorization.method.AuthorizationManagerBeforeMethodInterceptor;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class StockApprovalReadOnlyControllerTest {
    private StockDocService documents;
    private MockMvc http;

    @AfterEach void clearAuthentication() { SecurityContextHolder.clearContext(); }

    @BeforeEach void setUp() {
        documents = mock(StockDocService.class);
        http = MockMvcBuilders.standaloneSetup(new StockDocController(documents,
                mock(AuditDetailViewRecorder.class), mock(WarehouseTaskScopePort.class))).build();
    }

    @Test void removedAmendmentEndpointsCannotReachTheStockWriter() throws Exception {
        String path = "/api/stock/docs/" + UUID.randomUUID() + "/review";
        http.perform(get(path)).andExpect(status().isNotFound());
        http.perform(put(path).contentType(MediaType.APPLICATION_JSON)
                .content("{\"expectedSnapshot\":\"old\",\"approveNow\":true,\"document\":{\"items\":[]}}"))
                .andExpect(status().isNotFound());
        verifyNoInteractions(documents);
    }

    @Test void readonlyOutboundSnapshotAndExactReviewedApprovalRemainAvailable() throws Exception {
        UUID id = UUID.randomUUID();
        String token = "a".repeat(64);
        when(documents.reviewOutbound(id)).thenReturn(new StockDocOutboundReview(mock(StockDocDetail.class), token));
        http.perform(get("/api/stock/docs/" + id + "/outbound-review"))
                .andExpect(status().isOk());
        http.perform(post("/api/stock/docs/" + id + "/approve-reviewed")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"expectedReviewToken\":\"" + token + "\"}"))
                .andExpect(status().isOk());
        verify(documents).reviewOutbound(id);
        verify(documents).approveReviewed(eq(id), argThat(
                request -> token.equals(request.expectedReviewToken())));
    }

    @Test void reviewerCannotUpdateDraftsOrUseTheirExtensionFieldSaveLock() {
        SecurityContextHolder.getContext().setAuthentication(UsernamePasswordAuthenticationToken.authenticated(
                "reviewer", "unused", List.of(new SimpleGrantedAuthority("stock_doc:view"),
                        new SimpleGrantedAuthority("stock_doc:approve"))));
        ProxyFactory factory = new ProxyFactory(documents);
        factory.setProxyTargetClass(true);
        factory.addAdvisor(AuthorizationManagerBeforeMethodInterceptor.preAuthorize());
        StockDocService secured = (StockDocService) factory.getProxy();
        UUID id = UUID.randomUUID();
        StockDocSaveRequest request = new StockDocSaveRequest();
        assertThatThrownBy(() -> secured.update(id, request)).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> secured.lockDraftInputsForPlatform(id, request)).isInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(documents);
    }
}
