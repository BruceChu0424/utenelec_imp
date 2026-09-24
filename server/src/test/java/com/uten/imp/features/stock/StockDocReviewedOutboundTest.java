package com.uten.imp.features.stock;

import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.port.ProductionMutationFootprintPort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.stock.dto.StockDocReviewedApproveRequest;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.FulfillmentMutationLockTestSupport;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.mockito.junit.jupiter.MockitoSettings;
import org.mockito.quality.Strictness;
import org.junit.jupiter.api.extension.ExtendWith;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authorization.method.AuthorizationManagerBeforeMethodInterceptor;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
@MockitoSettings(strictness = Strictness.LENIENT)
class StockDocReviewedOutboundTest {
    @Mock EntityManager em;
    @Mock StockDocumentRepository docRepo;
    @Mock StockDocumentItemRepository itemRepo;
    @Mock StockBalanceAdjustmentCommandRepository balanceAdjustmentCommands;
    @Mock StockService stockService;
    @Mock TxSessionVars tx;
    @Mock StockDocAccessPolicy access;
    @Mock SecurityContextCurrentUser currentUser;
    @Mock ProductionStockTaskAccessPolicy productionStockTaskAccess;
    @Mock TaskClaimService taskClaim;
    @Mock EmployeeNameResolver nameResolver;
    @Mock FulfillmentMutationLocks mutationLocks;
    @Mock ProductionMutationFootprintPort mutationFootprints;
    @InjectMocks StockDocService service;
    StockDocument document;
    StockDocumentItem item;

    @BeforeEach
    void setup() {
        document = new StockDocument();
        document.setDocType("OTHER_OUT");
        document.setBillNo("OT-REVIEW-1");
        document.setWarehouseId(UUID.randomUUID());
        document.setMakerId(UUID.randomUUID());
        document.setUpdatedAt(Instant.parse("2026-09-12T00:00:00Z"));
        item = new StockDocumentItem();
        item.setDocId(document.getId());
        item.setGoodsId(UUID.randomUUID());
        item.setUnitId(UUID.randomUUID());
        item.setQty(new BigDecimal("10.0000"));
        item.setUnitRate(BigDecimal.ONE);
        item.setBaseQty(new BigDecimal("10.0000"));
        item.setPlace("A1");
        Query empty = mock(Query.class);
        when(empty.setParameter(anyString(), any())).thenReturn(empty);
        when(empty.getResultList()).thenReturn(List.of());
        when(empty.getSingleResult()).thenReturn(false);
        when(em.createNativeQuery(anyString())).thenReturn(empty);
        FulfillmentMutationLockTestSupport.emptyExecutionGraph(em);
        Query goods = mock(Query.class);
        when(goods.setParameter(anyString(), any())).thenReturn(goods);
        when(goods.getResultList()).thenReturn(java.util.Collections.singletonList(
                new Object[]{item.getGoodsId(), "G1", "Reviewed goods"}));
        when(em.createNativeQuery(contains("SELECT goods.id, goods.code, goods.name"))).thenReturn(goods);
        when(mutationLocks.acquire(any())).thenReturn(mock(FulfillmentMutationLocks.Guard.class));
        when(em.find(StockDocument.class, document.getId(), LockModeType.PESSIMISTIC_WRITE)).thenReturn(document);
        when(docRepo.findById(document.getId())).thenReturn(Optional.of(document));
        when(itemRepo.findByDocIdOrderByLineNoAsc(document.getId())).thenReturn(List.of(item));
        when(currentUser.requireEmployeeId()).thenReturn(UUID.randomUUID());
    }

    @AfterEach
    void clearSecurity() {
        SecurityContextHolder.clearContext();
    }

    @ParameterizedTest
    @ValueSource(strings = {"OTHER_OUT", "FINISHED_OUT"})
    void reviewedDocumentApprovesThroughExistingInventoryKernel(String type) {
        document.setDocType(type);
        var review = service.reviewOutbound(document.getId());
        assertThat(review.document().getItems()).hasSize(1);
        assertThat(review.document().getItems().getFirst().getQty()).isEqualByComparingTo("10");
        assertThat(review.reviewToken()).hasSize(64);
        var approved = service.approveReviewed(document.getId(), request(review.reviewToken()));
        assertThat(approved.getStatus()).isEqualTo((short) 1);
        verify(stockService).recordMovement(argThat(movement ->
                movement.sourceDocId().equals(document.getId())
                        && movement.warehouseId().equals(document.getWarehouseId())
                        && movement.qty().compareTo(BigDecimal.TEN) == 0));
        verify(docRepo).save(document);
    }

    @ParameterizedTest
    @ValueSource(strings = {"quantity", "warehouse", "goods", "unit", "source", "place", "closed", "revision"})
    void changesSinceReviewRejectBeforeStockPosting(String change) {
        String token = service.reviewOutbound(document.getId()).reviewToken();
        switch (change) {
            case "quantity" -> item.setQty(new BigDecimal("11"));
            case "warehouse" -> document.setWarehouseId(UUID.randomUUID());
            case "goods" -> item.setGoodsId(UUID.randomUUID());
            case "unit" -> item.setUnitRate(new BigDecimal("2"));
            case "source" -> item.setUpstreamItemId(UUID.randomUUID());
            case "place" -> item.setPlace("A2");
            case "closed" -> document.setClosed(true);
            case "revision" -> document.setUpdatedAt(document.getUpdatedAt().plusSeconds(1));
            default -> throw new AssertionError(change);
        }
        assertConflict(() -> service.approveReviewed(document.getId(), request(token)));
        verifyNoInteractions(stockService);
        verify(docRepo, never()).save(any());
    }

    @Test
    void editWinningWhileApprovalWaitsForDocumentLockCannotPassOldReview() {
        String token = service.reviewOutbound(document.getId()).reviewToken();
        // Model the other transaction committing while this command is waiting for the lock.
        when(em.find(StockDocument.class, document.getId(), LockModeType.PESSIMISTIC_WRITE))
                .thenAnswer(invocation -> {
                    item.setQty(new BigDecimal("27"));
                    document.setUpdatedAt(document.getUpdatedAt().plusSeconds(1));
                    return document;
                });
        assertConflict(() -> service.approveReviewed(document.getId(), request(token)));
        verifyNoInteractions(stockService);
        verify(docRepo, never()).save(any());
    }

    @Test
    void alreadyApprovedTokenCannotPostAgain() {
        String token = service.reviewOutbound(document.getId()).reviewToken();
        service.approveReviewed(document.getId(), request(token));
        clearInvocations(stockService, docRepo);
        assertConflict(() -> service.approveReviewed(document.getId(), request(token)));
        verifyNoInteractions(stockService);
        verify(docRepo, never()).save(any());
    }

    @ParameterizedTest
    @ValueSource(strings = {"DRAW", "OTHER_IN", "FINISHED_IN", "TRANSFER", "CHECK"})
    void endpointDoesNotBroadenApprovalToOtherDocumentTypes(String type) {
        document.setDocType(type);
        if ("DRAW".equals(type)) {
            Query requested = mock(Query.class);
            when(requested.setParameter(anyString(), any())).thenReturn(requested);
            when(requested.getSingleResult()).thenReturn(true);
            when(em.createNativeQuery(contains("fn_production_draw_requested"))).thenReturn(requested);
        }
        assertConflict(() -> service.reviewOutbound(document.getId()));
        assertConflict(() -> service.approveReviewed(document.getId(), request("a".repeat(64))));
        verifyNoInteractions(stockService);
    }

    @Test
    void ownerScopeStillRejectsCorrectToken() {
        String token = service.reviewOutbound(document.getId()).reviewToken();
        doThrow(new ApiException(ErrorCode.FORBIDDEN, "scope denied"))
                .when(access).requireWritable(eq(document.getMakerId()), anyString());
        assertThatThrownBy(() -> service.approveReviewed(document.getId(), request(token)))
                .isInstanceOfSatisfying(ApiException.class,
                        error -> assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
        verifyNoInteractions(stockService);
    }

    @Test
    void unreadableDocumentDoesNotRevealItsTypeOrReturnReviewToken() {
        document.setDocType("CHECK");
        doThrow(new ApiException(ErrorCode.NOT_FOUND, "not readable"))
                .when(access).requireReadable(eq(document.getMakerId()), anyString());
        assertThatThrownBy(() -> service.reviewOutbound(document.getId()))
                .isInstanceOfSatisfying(ApiException.class,
                        error -> assertThat(error.getCode()).isEqualTo(ErrorCode.NOT_FOUND));
        verifyNoInteractions(itemRepo, stockService);
    }

    @Test
    void missingTokenIsRejectedAndDecimalScaleDoesNotInventAChange() {
        String token = service.reviewOutbound(document.getId()).reviewToken();
        item.setQty(new BigDecimal("10"));
        assertThat(StockDocOutboundReviewFingerprint.of(document, List.of(item))).isEqualTo(token);
        assertThatThrownBy(() -> service.approveReviewed(document.getId(), request(null)))
                .isInstanceOfSatisfying(ApiException.class,
                        error -> assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        verifyNoInteractions(stockService);
    }

    @Test
    void readPermissionCannotCallReviewedApproveAndApproveCannotRead() {
        StockDocService endpointService = mock(StockDocService.class);
        StockDocController controller = new StockDocController(endpointService, mock(AuditDetailViewRecorder.class), null);
        ProxyFactory factory = new ProxyFactory(controller);
        factory.addAdvisor(AuthorizationManagerBeforeMethodInterceptor.preAuthorize());
        StockDocController secured = (StockDocController) factory.getProxy();
        authenticate("stock_doc:view");
        assertThatThrownBy(() -> secured.approveReviewed(document.getId(), request("a".repeat(64))))
                .isInstanceOf(AccessDeniedException.class);
        authenticate("stock_doc:approve");
        assertThatThrownBy(() -> secured.reviewOutbound(document.getId()))
                .isInstanceOf(AccessDeniedException.class);
        secured.approveReviewed(document.getId(), request("a".repeat(64)));
        verify(endpointService).approveReviewed(eq(document.getId()), any());
        verify(endpointService, never()).reviewOutbound(any());
    }

    private void authenticate(String authority) {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(
                "reviewer", "unused", List.of(new SimpleGrantedAuthority(authority))));
    }

    private static StockDocReviewedApproveRequest request(String token) {
        return new StockDocReviewedApproveRequest(token);
    }

    private static void assertConflict(org.assertj.core.api.ThrowableAssert.ThrowingCallable action) {
        assertThatThrownBy(action).isInstanceOfSatisfying(ApiException.class,
                error -> assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
    }
}
