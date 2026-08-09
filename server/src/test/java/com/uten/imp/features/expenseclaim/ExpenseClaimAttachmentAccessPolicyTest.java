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
                UUID.randomUUID(), employeeId, "applicant",
                Set.of(), Set.of("expense:apply"), false, true, false);

        policy.requireCanManageForUpdate(ownerId, user);

        verify(claims).findByIdForUpdate(ownerId);
    }
}
