package com.uten.imp.features.purchase;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptController;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.purchase.ret.PurchaseReturnController;
import com.uten.imp.features.purchase.ret.PurchaseReturnService;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptController;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.subcontract.ret.SubcontractReturnController;
import com.uten.imp.features.subcontract.ret.SubcontractReturnService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.http.MediaType;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.authorization.method.AuthorizationManagerBeforeMethodInterceptor;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.util.List;
import java.util.UUID;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class ProcurementPhysicalApprovalReadOnlyTest {
    @AfterEach void clearAuthentication() {
        SecurityContextHolder.clearContext();
    }

    @ParameterizedTest
    @MethodSource("documents")
    void removedReviewSaveAndApproveEndpointCannotReachAnyBusinessMutation(Document document) throws Exception {
        var mvc = MockMvcBuilders.standaloneSetup(document.controller()).build();
        UUID id = UUID.randomUUID();

        mvc.perform(post(document.path() + "/{id}/review", id)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"expectedSnapshot":"old-review-snapshot","approveNow":true,
                                 "document":{"items":[{"qty":"999","price":"0"}]}}
                                """))
                .andExpect(status().isNotFound());
        mvc.perform(get(document.path() + "/{id}/review", id)).andExpect(status().isNotFound());
        verifyNoInteractions(document.service());
    }

    @ParameterizedTest
    @MethodSource("documents")
    void approvalPermissionDoesNotGrantOrdinaryEditingOrPlatformColumnSaving(Document document) throws Exception {
        loginAsReviewer(document.permission());
        UUID id = UUID.randomUUID();
        Object request = document.requestType().getConstructor().newInstance();
        Object controller = secured(document.controller());
        Object service = secured(document.service());

        assertThatThrownBy(() -> controller.getClass().getMethod("update", UUID.class, document.requestType())
                        .invoke(controller, id, request))
                .hasCauseInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> service.getClass().getMethod("lockPlatformColumnSave", UUID.class, document.requestType())
                        .invoke(service, id, request))
                .hasCauseInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(document.service());
    }

    @ParameterizedTest
    @MethodSource("documents")
    void existingApprovalActionRemainsAvailableWithItsOwnPermission(Document document) throws Exception {
        loginAsReviewer(document.permission());
        UUID id = UUID.randomUUID();
        Object controller = secured(document.controller());

        controller.getClass().getMethod("approve", UUID.class).invoke(controller, id);
        document.service().getClass().getMethod("approve", UUID.class).invoke(verify(document.service()), id);
    }

    private static Object secured(Object target) {
        ProxyFactory factory = new ProxyFactory(target);
        factory.setProxyTargetClass(true);
        factory.addAdvisor(AuthorizationManagerBeforeMethodInterceptor.preAuthorize());
        return factory.getProxy();
    }

    private static void loginAsReviewer(String permission) {
        SecurityContextHolder.getContext().setAuthentication(UsernamePasswordAuthenticationToken.authenticated(
                "reviewer", "unused", List.of(new SimpleGrantedAuthority(permission + ":view"),
                        new SimpleGrantedAuthority(permission + ":approve"))));
    }

    private static Stream<Document> documents() {
        var purchaseReceipt = mock(PurchaseReceiptService.class);
        var purchaseReturn = mock(PurchaseReturnService.class);
        var subcontractReceipt = mock(SubcontractReceiptService.class);
        var subcontractReturn = mock(SubcontractReturnService.class);
        var audit = mock(AuditDetailViewRecorder.class);
        return Stream.of(
                new Document(new PurchaseReceiptController(purchaseReceipt, audit), purchaseReceipt,
                        com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest.class, "purchase_receipt", "/api/purchase/receipts"),
                new Document(new PurchaseReturnController(purchaseReturn, audit), purchaseReturn,
                        com.uten.imp.features.purchase.ret.dto.ReturnSaveRequest.class, "purchase_return", "/api/purchase/returns"),
                new Document(new SubcontractReceiptController(subcontractReceipt, audit), subcontractReceipt,
                        com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest.class, "subcontract_receipt", "/api/subcontract/receipts"),
                new Document(new SubcontractReturnController(subcontractReturn, audit), subcontractReturn,
                        com.uten.imp.features.subcontract.ret.dto.ReturnSaveRequest.class, "subcontract_return", "/api/subcontract/returns"));
    }

    private record Document(Object controller, Object service, Class<?> requestType, String permission, String path) {
        @Override public String toString() {
            return permission;
        }
    }
}
