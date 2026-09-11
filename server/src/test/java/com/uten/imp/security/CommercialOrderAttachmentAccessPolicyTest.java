package com.uten.imp.security;

import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.application.port.TaskClaimMutationGuardPort;
import com.uten.imp.common.concurrency.ProcurementMutationLocks;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery;
import com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy;
import com.uten.imp.features.purchase.order.PurchaseOrder;
import com.uten.imp.features.purchase.order.PurchaseOrderAttachmentAccessPolicy;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.SalesMutationFootprintService;
import com.uten.imp.features.sales.order.SalesOrder;
import com.uten.imp.features.sales.order.SalesOrderAttachmentAccessPolicy;
import com.uten.imp.features.sales.order.SalesPriceMasker;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.order.SubcontractOrder;
import com.uten.imp.features.subcontract.order.SubcontractOrderAttachmentAccessPolicy;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

import java.util.HashSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class CommercialOrderAttachmentAccessPolicyTest {
    enum Kind { SALES, PURCHASE, SUBCONTRACT }

    @ParameterizedTest @EnumSource(Kind.class)
    void quantityOnlyUserCannotReadOrUploadOriginalCommercialFiles(Kind kind) {
        var h = new Harness(kind); h.permissions.remove(h.permission("price:view"));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
        assertDoesNotThrow(() -> { h.permissions.add(h.permission("price:view")); h.policy.requireCanView(h.id, h.user()); });
    }

    @ParameterizedTest @EnumSource(Kind.class)
    void visibleDelegationDoesNotBecomeWritableAndHiddenOwnerDoesNotLeak(Kind kind) {
        var h = new Harness(kind);
        h.scope(Set.of(h.owner), Set.of());
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
        h.scope(Set.of(), Set.of());
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
        h.owner(null);
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
    }

    @ParameterizedTest @EnumSource(Kind.class)
    void effectiveClosedDeletedAndMissingOrdersCannotHaveFilesReplaced(Kind kind) {
        var h = new Harness(kind); h.status((short) 1);
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManage(h.id, h.user()));
        h.status((short) 0); h.closed(true);
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManage(h.id, h.user()));
        h.deleted(true);
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(UUID.randomUUID(), h.user()));
        denied(ErrorCode.VALIDATION_FAILED, () -> h.policy.requireCanManage(null, h.user()));
    }

    @ParameterizedTest @EnumSource(Kind.class)
    void confirmAndDeleteLockAndRefreshActualHeaderAfterBusinessPrelock(Kind kind) {
        var h = new Harness(kind);
        h.policy.requireCanManageForUpdate(h.id, h.user());
        if (kind == Kind.SALES) {
            var sequence = inOrder(h.salesLocks, h.em, h.claims);
            sequence.verify(h.salesLocks).lockOrder(h.id, List.of());
            sequence.verify(h.em).find(SalesOrder.class, h.id, LockModeType.PESSIMISTIC_WRITE);
            sequence.verify(h.em).refresh(h.sales, LockModeType.PESSIMISTIC_WRITE);
            sequence.verify(h.claims).requireNoActiveClaim("SALES_ORDER_FINANCE_CONFIRM", h.id.toString());
        } else {
            var sequence = inOrder(h.procurementLocks, h.em, h.approvals, h.guard);
            sequence.verify(h.procurementLocks).order(kind.name(), h.id);
            if (kind == Kind.PURCHASE) sequence.verify(h.em).find(PurchaseOrder.class, h.id, LockModeType.PESSIMISTIC_WRITE);
            else sequence.verify(h.em).find(SubcontractOrder.class, h.id, LockModeType.PESSIMISTIC_WRITE);
            sequence.verify(h.em).refresh(h.entity(), LockModeType.PESSIMISTIC_WRITE);
            sequence.verify(h.approvals).requireMutable(kind.name(), h.id);
            sequence.verify(h.guard).verifyUnchanged();
        }
    }

    @ParameterizedTest @EnumSource(Kind.class)
    void concurrentApprovalObservedAfterWaitRejectsStaleDraft(Kind kind) {
        var h = new Harness(kind);
        doAnswer(invocation -> { h.status((short) 1); return null; })
                .when(h.em).refresh(h.entity(), LockModeType.PESSIMISTIC_WRITE);
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManageForUpdate(h.id, h.user()));
        verifyNoInteractions(h.claims);
        verify(h.guard, never()).verifyUnchanged();
    }

    @ParameterizedTest @EnumSource(value = Kind.class, names = {"PURCHASE", "SUBCONTRACT"})
    void exactPendingFinanceReviewerCanReadButCannotManageHiddenOrder(Kind kind) {
        var h = new Harness(kind); h.scope(Set.of(), Set.of());
        h.permissions.remove(h.permission("view")); h.permissions.add("finance_order_approval:view");
        when(h.approvals.canCurrentActorReviewPending(kind.name(), h.id)).thenReturn(true);
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
        h.permissions.remove(h.permission("price:view"));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanView(h.id, h.user()));
        h.permissions.add(h.permission("price:view"));
        when(h.approvals.canCurrentActorReviewPending(kind.name(), h.id)).thenReturn(false);
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
    }

    @ParameterizedTest @EnumSource(value = Kind.class, names = {"PURCHASE", "SUBCONTRACT"})
    void financePagePermissionDoesNotBorrowOrderScopeForUnassignedOrLegacyOrders(Kind kind) {
        var h = new Harness(kind);
        h.permissions.remove(h.permission("view"));
        h.permissions.add("finance_order_approval:view");
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
        h.owner(null);
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
        when(h.approvals.canCurrentActorReviewPending(kind.name(), h.id)).thenReturn(true);
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        h.permissions.remove("finance_order_approval:view");
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
    }

    @ParameterizedTest @EnumSource(Kind.class)
    void concurrentOwnerChangeCannotReuseThePreviousWritableScope(Kind kind) {
        var h = new Harness(kind);
        doAnswer(invocation -> { h.owner(UUID.randomUUID()); return null; })
                .when(h.em).refresh(h.entity(), LockModeType.PESSIMISTIC_WRITE);
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanManageForUpdate(h.id, h.user()));
        verifyNoInteractions(h.claims);
        verify(h.guard, never()).verifyUnchanged();
    }

    @ParameterizedTest @EnumSource(value = Kind.class, names = {"PURCHASE", "SUBCONTRACT"})
    void financeSubmissionDuringLockWaitIsCheckedAgainBeforeFileMutation(Kind kind) {
        var h = new Harness(kind);
        doAnswer(invocation -> {
            doThrow(new ApiException(ErrorCode.CONFLICT, "PENDING"))
                    .when(h.approvals).requireMutable(kind.name(), h.id);
            return null;
        }).when(h.em).refresh(h.entity(), LockModeType.PESSIMISTIC_WRITE);
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManageForUpdate(h.id, h.user()));
        verify(h.guard, never()).verifyUnchanged();
    }

    @ParameterizedTest @EnumSource(value = Kind.class, names = {"PURCHASE", "SUBCONTRACT"})
    void submittedFinanceCaseBlocksEvenOtherwiseWritableDraft(Kind kind) {
        var h = new Harness(kind);
        doThrow(new ApiException(ErrorCode.CONFLICT, "PENDING"))
                .when(h.approvals).requireMutable(kind.name(), h.id);
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManageForUpdate(h.id, h.user()));
        verifyNoInteractions(h.procurementLocks);
    }

    @Test void salesFinanceReviewerReadsOnlyOrdersThatEnteredTheFinanceFlowAndNeverManages() {
        var h = new Harness(Kind.SALES); h.scope(Set.of(), Set.of());
        h.permissions.remove("sales_order:view"); h.permissions.add("sales_order_finance:view");
        // 纯草稿（未提交）：财务页面权限不得提前读取合同原件。
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
        // 已提交待确认：可读不可管理，且不要求销售归属/价格权限。
        h.status((short) 1); h.permissions.remove(h.permission("price:view"));
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
        // 财务退回（订单回草稿等待修改）与财务已确认：仍可读。
        h.status((short) 0); h.sales.setFinanceRejected(true);
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        h.sales.setFinanceRejected(false); h.status((short) 1); h.sales.setFinanceConfirmed(true);
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.CONFLICT, () -> { h.permissions.add(h.permission("price:view")); h.permissions.add("sales_order:edit"); h.scope(Set.of(h.owner), Set.of(h.owner)); h.policy.requireCanManage(h.id, h.user()); });
        // 收回财务查看权：回到销售口径（无销售权限 → 不可见）。
        h.permissions.remove("sales_order_finance:view"); h.scope(Set.of(), Set.of());
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
    }

    @Test void salesDraftStaysInvisibleToFinanceEvenWhenFinanceAlsoHoldsSalesViewOutsideScope() {
        var h = new Harness(Kind.SALES); h.scope(Set.of(), Set.of());
        h.permissions.add("sales_order_finance:view");
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
        h.status((short) 1);
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
    }

    @Test void salesReturnedRevisionMayChangeFilesButEffectiveOrClaimedContractMayNot() {
        var h = new Harness(Kind.SALES); h.status((short) 1); h.sales.setFinanceRejected(true);
        assertDoesNotThrow(() -> h.policy.requireCanManageForUpdate(h.id, h.user()));
        h.sales.setFinanceConfirmed(true);
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManage(h.id, h.user()));
        h.sales.setFinanceConfirmed(false); h.sales.setStopped(true);
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManage(h.id, h.user()));
        h.sales.setStopped(false);
        doThrow(new ApiException(ErrorCode.CONFLICT, "active review"))
                .when(h.claims).requireNoActiveClaim("SALES_ORDER_FINANCE_CONFIRM", h.id.toString());
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManageForUpdate(h.id, h.user()));
    }

    private static void denied(ErrorCode code, Runnable operation) {
        assertEquals(code, assertThrows(ApiException.class, operation::run).getCode());
    }

    private static final class Harness {
        final Kind kind;
        final UUID id = UUID.randomUUID(), owner = UUID.randomUUID();
        final EntityManager em = mock(EntityManager.class);
        final OwnerVisibility ownership = mock(OwnerVisibility.class);
        final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        final ProcurementApprovalProjectionQuery approvals = mock(ProcurementApprovalProjectionQuery.class);
        final ProcurementMutationLocks procurementLocks = mock(ProcurementMutationLocks.class);
        final SalesMutationFootprintService salesLocks = mock(SalesMutationFootprintService.class);
        final TaskClaimMutationGuardPort claims = mock(TaskClaimMutationGuardPort.class);
        final FulfillmentMutationLocks.Guard guard = mock(FulfillmentMutationLocks.Guard.class);
        final Set<String> permissions = new HashSet<>();
        final SalesOrder sales = new SalesOrder();
        final PurchaseOrder purchase = new PurchaseOrder();
        final SubcontractOrder subcontract = new SubcontractOrder();
        final AttachmentOwnerAccessPolicy policy;

        Harness(Kind kind) {
            this.kind = kind;
            permissions.addAll(Set.of(permission("view"), permission("edit"), permission("price:view")));
            when(current.get()).thenAnswer(ignored -> Optional.of(user()));
            sales.setId(id); purchase.setId(id); subcontract.setId(id);
            owner(owner); status((short) 0); scope(Set.of(owner), Set.of(owner));
            when(em.find(SalesOrder.class, id)).thenReturn(sales);
            when(em.find(PurchaseOrder.class, id)).thenReturn(purchase);
            when(em.find(SubcontractOrder.class, id)).thenReturn(subcontract);
            when(em.find(SalesOrder.class, id, LockModeType.PESSIMISTIC_WRITE)).thenReturn(sales);
            when(em.find(PurchaseOrder.class, id, LockModeType.PESSIMISTIC_WRITE)).thenReturn(purchase);
            when(em.find(SubcontractOrder.class, id, LockModeType.PESSIMISTIC_WRITE)).thenReturn(subcontract);
            when(procurementLocks.order(kind.name(), id)).thenReturn(guard);
            var prices = new CommercialPriceVisibility(current);
            policy = switch (kind) {
                case SALES -> new SalesOrderAttachmentAccessPolicy(em, new SalesDocumentAccessPolicy(ownership, current),
                        new SalesPriceMasker(current), salesLocks, claims);
                case PURCHASE -> new PurchaseOrderAttachmentAccessPolicy(em, new PurchaseDocumentAccessPolicy(ownership, current), prices, approvals, procurementLocks);
                case SUBCONTRACT -> new SubcontractOrderAttachmentAccessPolicy(em, new SubcontractDocumentAccessPolicy(ownership, current), prices, approvals, procurementLocks);
            };
            assertEquals(kind.name() + "_ORDER", policy.ownerType());
        }
        String permission(String suffix) { return kind.name().toLowerCase(java.util.Locale.ROOT) + "_order:" + suffix; }
        AuthUser user() { return new AuthUser(owner, owner, "owner", Set.of(), Set.copyOf(permissions), false, true, false); }
        void scope(Set<UUID> readable, Set<UUID> writable) {
            when(ownership.evaluate(anyString(), anyString())).thenReturn(new OwnerVisibility.OwnerScope(false, readable, writable));
        }
        Object entity() { return switch(kind) { case SALES -> sales; case PURCHASE -> purchase; case SUBCONTRACT -> subcontract; }; }
        void owner(UUID owner) { sales.setOwnerEmployeeId(owner); purchase.setMakerId(owner); subcontract.setMakerId(owner); }
        void status(short status) { sales.setStatus(status); purchase.setStatus(status); subcontract.setStatus(status); }
        void closed(boolean value) { sales.setClosed(value); purchase.setClosed(value); subcontract.setClosed(value); }
        void deleted(boolean value) { sales.setDeleted(value); purchase.setDeleted(value); subcontract.setDeleted(value); }
    }
}
