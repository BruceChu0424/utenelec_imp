package com.uten.imp.features.sales;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.application.port.CustomerShipmentInventoryPort;
import com.uten.imp.application.port.TaskClaimMutationGuardPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.quote.SalesQuote;
import com.uten.imp.features.sales.quote.SalesQuoteAttachmentAccessPolicy;
import com.uten.imp.features.sales.ret.SalesReturn;
import com.uten.imp.features.sales.ret.SalesReturnAttachmentAccessPolicy;
import com.uten.imp.features.sales.shipment.CustomerShipmentPolicy;
import com.uten.imp.features.sales.shipment.SalesShipment;
import com.uten.imp.features.sales.shipment.SalesShipmentAttachmentAccessPolicy;
import com.uten.imp.security.AuthUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

import java.time.OffsetDateTime;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class SalesDocumentAttachmentAccessPolicyTest {
    enum Kind { QUOTE, RETURN, ORDER_SHIPMENT, DIRECT_SHIPMENT }

    @ParameterizedTest @EnumSource(Kind.class)
    void documentViewAndWriteGrantsStaySeparate(Kind kind) {
        var h = new Harness(kind);
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        h.permissions.remove(h.prefix + ":edit");
        assertThrows(ApiException.class, () -> h.policy.requireCanManage(h.id, h.user()));
        h.permissions.remove(h.prefix + ":view");
        assertThrows(ApiException.class, () -> h.policy.requireCanView(h.id, h.user()));
        verify(h.access, never()).requireWritable(any(), any());
    }

    @ParameterizedTest @EnumSource(Kind.class)
    void ownershipIsCheckedAndNullOrUnknownIdsDoNotResolve(Kind kind) {
        var h = new Harness(kind);
        h.policy.requireCanManage(h.id, h.user());
        verify(h.access).requireWritable(eq(h.owner), anyString());
        doThrow(new ApiException(ErrorCode.FORBIDDEN, "outside scope"))
                .when(h.access).requireWritable(eq(h.owner), anyString());
        assertThrows(ApiException.class, () -> h.policy.requireCanManage(h.id, h.user()));
        assertThrows(ApiException.class, () -> h.policy.requireCanView(null, h.user()));
        assertThrows(ApiException.class, () -> h.policy.requireCanView(UUID.randomUUID(), h.user()));
    }

    @ParameterizedTest @EnumSource(Kind.class)
    void approvalAfterLockWaitFreezesOriginalFile(Kind kind) {
        var h = new Harness(kind);
        doAnswer(call -> { h.approve(); return null; }).when(h.em)
                .refresh(h.entity(), LockModeType.PESSIMISTIC_WRITE);
        assertThrows(ApiException.class, () -> h.policy.requireCanManageForUpdate(h.id, h.user()));
        verify(h.em).refresh(h.entity(), LockModeType.PESSIMISTIC_WRITE);
        verifyNoInteractions(h.claims, h.inventory);
    }

    @ParameterizedTest @EnumSource(Kind.class)
    void closedAndDeletedDocumentsCannotHaveOriginalsReplaced(Kind kind) {
        var h = new Harness(kind);
        if (h.quote != null) h.quote.setClosed(true);
        else if (h.returned != null) h.returned.setClosed(true);
        else h.shipment.setClosed(true);
        assertThrows(ApiException.class, () -> h.policy.requireCanManage(h.id, h.user()));
        ((com.uten.imp.common.domain.SoftDeletableEntity) h.entity()).setDeleted(true);
        assertThrows(ApiException.class, () -> h.policy.requireCanView(h.id, h.user()));
    }

    @ParameterizedTest @EnumSource(Kind.class)
    void validDraftUsesTheBusinessLockOrderBeforeFinalOwnerCheck(Kind kind) {
        var h = new Harness(kind);
        h.policy.requireCanManageForUpdate(h.id, h.user());
        var sequence = inOrder(h.mutations, h.em, h.claims, h.inventory);
        if (kind == Kind.RETURN) sequence.verify(h.mutations).lockReturn(h.id, List.of());
        if (h.shipment != null) sequence.verify(h.mutations).lockShipment(h.id, List.of());
        sequence.verify(h.em).refresh(h.entity(), LockModeType.PESSIMISTIC_WRITE);
        if (h.shipment != null) {
            sequence.verify(h.claims).requireNoActiveClaim(CustomerShipmentPolicy.CLAIM_TYPE, h.id.toString());
            sequence.verify(h.inventory).requireNoUnreleased(h.id);
        }
    }

    @Test void directShipmentCannotBorrowOrderShipmentPermissions() {
        var h = new Harness(Kind.DIRECT_SHIPMENT);
        h.permissions.remove("sales_other_shipment:view");
        h.permissions.remove("sales_other_shipment:edit");
        h.permissions.addAll(Set.of("sales_shipment:view", "sales_shipment:edit"));
        assertThrows(ApiException.class, () -> h.policy.requireCanView(h.id, h.user()));
        assertThrows(ApiException.class, () -> h.policy.requireCanManage(h.id, h.user()));
    }

    @Test void quantityOnlyShipmentViewerCannotReadCommercialOriginals() {
        var h = new Harness(Kind.ORDER_SHIPMENT);
        h.permissions.remove("sales_order:price:view");
        assertThrows(ApiException.class, () -> h.policy.requireCanView(h.id, h.user()));
        h.permissions.add("finance_shipment_audit");
        assertThrows(ApiException.class, () -> h.policy.requireCanView(h.id, h.user()));
        h.shipment.setFinanceRejected(true);
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
    }

    @Test void submittedFinanceApprovedAndShippedShipmentsAreImmutable() {
        var h = new Harness(Kind.ORDER_SHIPMENT);
        h.shipment.setSalesConfirmedAt(OffsetDateTime.now());
        h.shipment.setSalesConfirmedBy(h.owner);
        h.shipment.setSalesConfirmedRevision(h.shipment.getReviewRevision());
        assertThrows(ApiException.class, () -> h.policy.requireCanManage(h.id, h.user()));
        h.shipment.setFinanceRejected(true);
        assertDoesNotThrow(() -> h.policy.requireCanManage(h.id, h.user()));
        h.shipment.setFinanceAudit((short) 1);
        assertThrows(ApiException.class, () -> h.policy.requireCanManage(h.id, h.user()));
        h.shipment.setFinanceAudit((short) 0);
        h.shipment.setWarehouseWorkStatus(SalesShipment.WORK_SHIPPED);
        assertThrows(ApiException.class, () -> h.policy.requireCanManage(h.id, h.user()));
    }

    private static final class Harness {
        final UUID id = UUID.randomUUID(), owner = UUID.randomUUID();
        final EntityManager em = mock(EntityManager.class);
        final SalesDocumentAccessPolicy access = mock(SalesDocumentAccessPolicy.class);
        final SalesMutationFootprintService mutations = mock(SalesMutationFootprintService.class);
        final TaskClaimMutationGuardPort claims = mock(TaskClaimMutationGuardPort.class);
        final CustomerShipmentInventoryPort inventory = mock(CustomerShipmentInventoryPort.class);
        final Set<String> permissions = new HashSet<>();
        final String prefix;
        final AttachmentOwnerAccessPolicy policy;
        SalesQuote quote;
        SalesReturn returned;
        SalesShipment shipment;
        Harness(Kind kind) {
            prefix = switch (kind) {
                case QUOTE -> "sales_quote"; case RETURN -> "sales_return";
                case DIRECT_SHIPMENT -> "sales_other_shipment"; case ORDER_SHIPMENT -> "sales_shipment";
            };
            permissions.addAll(Set.of(prefix + ":view", prefix + ":edit", "sales_order:price:view"));
            if (kind == Kind.QUOTE) {
                quote = new SalesQuote(); quote.setId(id); quote.setMakerId(owner);
                when(em.find(SalesQuote.class, id)).thenReturn(quote);
                when(em.find(SalesQuote.class, id, LockModeType.PESSIMISTIC_WRITE)).thenReturn(quote);
                policy = new SalesQuoteAttachmentAccessPolicy(em, access);
            } else if (kind == Kind.RETURN) {
                returned = new SalesReturn(); returned.setId(id); returned.setOwnerEmployeeId(owner);
                when(em.find(SalesReturn.class, id)).thenReturn(returned);
                when(em.find(SalesReturn.class, id, LockModeType.PESSIMISTIC_WRITE)).thenReturn(returned);
                policy = new SalesReturnAttachmentAccessPolicy(em, access, mutations);
            } else {
                shipment = new SalesShipment(); shipment.setId(id); shipment.setOwnerEmployeeId(owner);
                shipment.setShipmentKind(kind == Kind.DIRECT_SHIPMENT ? CustomerShipmentPolicy.DIRECT : CustomerShipmentPolicy.ORDER);
                when(em.find(SalesShipment.class, id)).thenReturn(shipment);
                when(em.find(SalesShipment.class, id, LockModeType.PESSIMISTIC_WRITE)).thenReturn(shipment);
                policy = new SalesShipmentAttachmentAccessPolicy(em, access, mutations, claims, inventory);
            }
        }
        Object entity() { return quote != null ? quote : returned != null ? returned : shipment; }
        void approve() {
            if (quote != null) quote.setStatus((short) 1);
            else if (returned != null) returned.setStatus((short) 1);
            else shipment.setStatus((short) 1);
        }
        AuthUser user() { return new AuthUser(UUID.randomUUID(), owner, "test", Set.of(), Set.copyOf(permissions), false, true, false); }
    }
}
