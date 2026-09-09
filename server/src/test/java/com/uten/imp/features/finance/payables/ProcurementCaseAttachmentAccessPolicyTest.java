package com.uten.imp.features.finance.payables;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class ProcurementCaseAttachmentAccessPolicyTest {
    @ParameterizedTest @ValueSource(strings={"procurement_iqc_rejection:view","procurement_iqc_rejection:amount:view"})
    void iqcOriginalsNeedBothCaseAndAmountPermissionBeforeReadingOwner(String missing) {
        var h=new Iqc();h.permissions.remove(missing);
        denied(ErrorCode.FORBIDDEN,()->h.policy.requireCanView(h.id,h.user()));
        denied(ErrorCode.FORBIDDEN,()->h.policy.requireCanManageForUpdate(h.id,h.user()));
        verifyNoInteractions(h.service);
    }

    @Test void iqcUsesOriginalOwnerScopeAndRespectsServerMask() {
        var h=new Iqc();when(h.service.attachmentOwnerView(h.id)).thenThrow(new ApiException(ErrorCode.NOT_FOUND,"other case"));
        denied(ErrorCode.NOT_FOUND,()->h.policy.requireCanView(h.id,h.user()));
        doReturn(h.view).when(h.service).attachmentOwnerView(h.id);when(h.view.priceMasked()).thenReturn(true);
        denied(ErrorCode.FORBIDDEN,()->h.policy.requireCanView(h.id,h.user()));
        denied(ErrorCode.FORBIDDEN,()->h.policy.requireCanManage(h.id,h.user()));
    }

    @ParameterizedTest @ValueSource(strings={"RECORD_RETURN","CONFIRM_CREDIT"})
    void iqcCurrentServerActionAllowsOriginalEvidenceManagement(String action) {
        var h=new Iqc();when(h.view.allowedActions()).thenReturn(List.of(action));
        assertDoesNotThrow(()->h.policy.requireCanManage(h.id,h.user()));
        assertDoesNotThrow(()->h.policy.requireCanManageForUpdate(h.id,h.user()));
        verify(h.service).lockAttachmentOwner(h.id);
    }

    @ParameterizedTest @ValueSource(strings={"REVERSE","CLOSE_NO_CREDIT","RETRY_FINANCE_PROJECTION",""})
    void iqcCompletedOrOtherActionsDoNotAuthorizeReplacingOriginalEvidence(String action) {
        var h=new Iqc();when(h.view.allowedActions()).thenReturn(List.of(action));
        assertDoesNotThrow(()->h.policy.requireCanView(h.id,h.user()));
        denied(ErrorCode.CONFLICT,()->h.policy.requireCanManage(h.id,h.user()));
    }

    @Test void iqcConfirmationAndDeletionReadCurrentStateUnderOriginalBusinessLock() {
        var h=new Iqc();var decided=mock(ProcurementIqcRejectionContracts.CaseItem.class);
        when(decided.allowedActions()).thenReturn(List.of("REVERSE"));when(h.service.lockAttachmentOwner(h.id)).thenReturn(decided);
        denied(ErrorCode.CONFLICT,()->h.policy.requireCanManageForUpdate(h.id,h.user()));
        verify(h.service).lockAttachmentOwner(h.id);verify(h.service,never()).attachmentOwnerView(any());
    }

    @ParameterizedTest @ValueSource(strings={"subcontract_loss_claim:view","finance:view:all"})
    void lossOriginalsNeedTheOriginalFinancialVisibility(String missing) {
        var h=new Loss();h.permissions.remove(missing);
        denied(ErrorCode.FORBIDDEN,()->h.policy.requireCanView(h.id,h.user()));verifyNoInteractions(h.service);
    }

    @Test void lossViewerCanReadButCannotChangeEvidence() {
        var h=new Loss();h.permissions.remove("subcontract_loss_claim:review");
        assertDoesNotThrow(()->h.policy.requireCanView(h.id,h.user()));
        denied(ErrorCode.FORBIDDEN,()->h.policy.requireCanManage(h.id,h.user()));
        verify(h.service,never()).lockAttachmentOwner(any());
    }

    @ParameterizedTest @ValueSource(strings={"OPEN","DISPUTED"})
    void undecidedLossEvidenceCanBeManaged(String status) {
        var h=new Loss();when(h.view.status()).thenReturn(status);
        assertDoesNotThrow(()->h.policy.requireCanManageForUpdate(h.id,h.user()));
        verify(h.service).lockAttachmentOwner(h.id);verify(h.service,never()).attachmentOwnerView(any());
    }

    @ParameterizedTest @ValueSource(strings={"ACCEPTED","AWAITING_FULFILLMENT","RESOLVED","REVERSED"})
    void lossDecisionFreezesItsOriginalEvidenceWhileKeepingReadAccess(String status) {
        var h=new Loss();when(h.view.status()).thenReturn(status);
        assertDoesNotThrow(()->h.policy.requireCanView(h.id,h.user()));
        denied(ErrorCode.CONFLICT,()->h.policy.requireCanManage(h.id,h.user()));
    }

    @Test void lossDecisionCommittedWhileWaitingForLockRejectsPendingFileChange() {
        var h=new Loss();var decided=mock(SubcontractLossClaimContracts.CaseSummary.class);
        when(decided.status()).thenReturn("AWAITING_FULFILLMENT");when(h.service.lockAttachmentOwner(h.id)).thenReturn(decided);
        denied(ErrorCode.CONFLICT,()->h.policy.requireCanManageForUpdate(h.id,h.user()));
        when(h.view.priceMasked()).thenReturn(true);
        denied(ErrorCode.FORBIDDEN,()->h.policy.requireCanView(h.id,h.user()));
    }

    @Test void missingOwnersAreRejectedBeforeBusinessReads() {
        var iqc=new Iqc();var loss=new Loss();
        denied(ErrorCode.VALIDATION_FAILED,()->iqc.policy.requireCanManage(null,iqc.user()));
        denied(ErrorCode.VALIDATION_FAILED,()->loss.policy.requireCanView(null,loss.user()));
        verifyNoInteractions(iqc.service,loss.service);
        assertEquals("PROCUREMENT_IQC_REJECTION",iqc.policy.ownerType());assertEquals("SUBCONTRACT_LOSS_CASE",loss.policy.ownerType());
    }

    private static void denied(ErrorCode code,Runnable action){assertEquals(code,assertThrows(ApiException.class,action::run).getCode());}
    private static class Iqc {
        final UUID id=UUID.randomUUID();
        final Set<String> permissions=new HashSet<>(Set.of("procurement_iqc_rejection:view","procurement_iqc_rejection:amount:view"));
        final ProcurementIqcRejectionService service=mock(ProcurementIqcRejectionService.class);
        final ProcurementIqcRejectionContracts.CaseItem view=mock(ProcurementIqcRejectionContracts.CaseItem.class);
        final ProcurementIqcRejectionAttachmentAccessPolicy policy=new ProcurementIqcRejectionAttachmentAccessPolicy(service);
        Iqc(){when(service.attachmentOwnerView(id)).thenReturn(view);when(service.lockAttachmentOwner(id)).thenReturn(view);when(view.allowedActions()).thenReturn(List.of("RECORD_RETURN"));}
        AuthUser user(){return new AuthUser(id,id,"case-owner",Set.of(),Set.copyOf(permissions),false,true,false);}
    }
    private static class Loss {
        final UUID id=UUID.randomUUID();
        final Set<String> permissions=new HashSet<>(Set.of("subcontract_loss_claim:view","finance:view:all","subcontract_loss_claim:review"));
        final SubcontractLossClaimService service=mock(SubcontractLossClaimService.class);
        final SubcontractLossClaimContracts.CaseSummary view=mock(SubcontractLossClaimContracts.CaseSummary.class);
        final SubcontractLossAttachmentAccessPolicy policy=new SubcontractLossAttachmentAccessPolicy(service);
        Loss(){when(service.attachmentOwnerView(id)).thenReturn(view);when(service.lockAttachmentOwner(id)).thenReturn(view);when(view.status()).thenReturn("OPEN");}
        AuthUser user(){return new AuthUser(id,id,"case-owner",Set.of(),Set.copyOf(permissions),false,true,false);}
    }
}
