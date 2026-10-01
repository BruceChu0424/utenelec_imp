package com.uten.imp.features.expenseclaim;

import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ExpenseClaimAttachmentAccessPolicyTest {

    @Test
    void updateAuthorizationLocksTheSameOwnerRowAsSubmit() {
        ExpenseClaimRepository claims = mock(ExpenseClaimRepository.class);
        ExpenseClaimAttachmentAccessPolicy policy =
                new ExpenseClaimAttachmentAccessPolicy(claims);
        UUID employeeId = UUID.randomUUID();
        UUID ownerId = UUID.randomUUID();
        ExpenseClaim claim = new ExpenseClaim();
        claim.setApplicantId(employeeId);
        claim.setStatus("DRAFT");
        when(claims.findByIdForUpdate(ownerId)).thenReturn(Optional.of(claim));
        AuthUser user = new AuthUser(
                UUID.randomUUID(), employeeId, "applicant", Set.of("expense:apply"), false, true, false);

        policy.requireCanManageForUpdate(ownerId, user);

        verify(claims).findByIdForUpdate(ownerId);
    }
    @Test void deletedDraftRemainsReadableOnlyThroughHistoryAndCannotBeEdited() {
        ExpenseClaimRepository claims=mock(ExpenseClaimRepository.class);
        var policy=new ExpenseClaimAttachmentAccessPolicy(claims);
        UUID employee=UUID.randomUUID(),id=UUID.randomUUID();
        var claim=new ExpenseClaim();claim.setApplicantId(employee);claim.setStatus("DRAFT");claim.setDeleted(true);
        when(claims.findById(id)).thenReturn(Optional.of(claim));
        when(claims.findByIdForUpdate(id)).thenReturn(Optional.of(claim));
        var user=new AuthUser(UUID.randomUUID(),employee,"owner",Set.of("expense:apply"),false,true,false);
        org.junit.jupiter.api.Assertions.assertDoesNotThrow(()->policy.requireCanViewHistory(id,user));
        org.junit.jupiter.api.Assertions.assertThrows(com.uten.imp.common.web.ApiException.class,()->policy.requireCanView(id,user));
        org.junit.jupiter.api.Assertions.assertThrows(com.uten.imp.common.web.ApiException.class,()->policy.requireCanManageForUpdate(id,user));
        var foreign=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"foreign",Set.of("expense:apply"),false,true,false);
        org.junit.jupiter.api.Assertions.assertThrows(com.uten.imp.common.web.ApiException.class,()->policy.requireCanViewHistory(id,foreign));
    }
}
