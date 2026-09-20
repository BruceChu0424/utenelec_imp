package com.uten.imp.features.expenseclaim;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
class ExpensePaymentProofAttachmentAccessPolicyTest {
    @Test void onlyIndependentPayerCanModifyApprovedPaymentProofUnderClaimLock() {
        UUID applicant=UUID.randomUUID(),reviewer=UUID.randomUUID(),payer=UUID.randomUUID();
        var claim=claim(applicant,reviewer,"APPROVED");
        var repo=mock(ExpenseClaimRepository.class);
        when(repo.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        var policy=new ExpensePaymentProofAttachmentAccessPolicy(repo,mock(ExpenseClaimAttachmentAccessPolicy.class));
        assertThatCode(()->policy.requireCanManageForUpdate(claim.getId(),actor(payer))).doesNotThrowAnyException();
        assertThatThrownBy(()->policy.requireCanManageForUpdate(claim.getId(),actor(applicant))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->policy.requireCanManageForUpdate(claim.getId(),actor(reviewer))).isInstanceOf(ApiException.class);
        verify(repo,times(3)).findByIdForUpdate(claim.getId());
    }
    @Test void paidPaymentProofRemainsImmutableAndReadScopeUsesParentClaim() {
        var claim=claim(UUID.randomUUID(),UUID.randomUUID(),"PAID");var payer=actor(UUID.randomUUID());
        var repo=mock(ExpenseClaimRepository.class);when(repo.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        var read=mock(ExpenseClaimAttachmentAccessPolicy.class);
        var policy=new ExpensePaymentProofAttachmentAccessPolicy(repo,read);
        assertThatThrownBy(()->policy.requireCanManageForUpdate(claim.getId(),payer)).isInstanceOf(ApiException.class);
        policy.requireCanView(claim.getId(),payer);verify(read).requireCanView(claim.getId(),payer);
    }
    private ExpenseClaim claim(UUID applicant,UUID reviewer,String status){var claim=new ExpenseClaim();claim.setApplicantId(applicant);claim.setApprovedBy(reviewer);claim.setStatus(status);return claim;}
    private AuthUser actor(UUID employee){return new AuthUser(UUID.randomUUID(),employee,"payer",Set.of(),Set.of("expense:pay"),false,true,false);}
}
