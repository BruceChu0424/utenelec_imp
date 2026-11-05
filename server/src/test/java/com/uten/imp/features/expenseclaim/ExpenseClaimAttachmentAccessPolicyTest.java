package com.uten.imp.features.expenseclaim;

import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.anyString;
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
        var policy=policyWithReadAccess(claims);
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

    /** 2026-11-04：附件读取口径与 ExpenseClaimService#detail 统一后新增字段注入的 ExpenseClaimReadPolicy；
     *  单测构造需按 ExpenseClaimServiceTest 同款夹具补齐读权限依赖。 */
    private static ExpenseClaimAttachmentAccessPolicy policyWithReadAccess(ExpenseClaimRepository claims) {
        var owners=mock(com.uten.imp.security.OwnerVisibility.class);
        when(owners.evaluate(anyString(),anyString()))
                .thenReturn(new com.uten.imp.security.OwnerVisibility.OwnerScope(false,Set.of(),Set.of()));
        var readers=new ExpenseClaimReadPolicy(owners);
        org.springframework.test.util.ReflectionTestUtils.setField(readers,"approvalPolicy",mock(ExpenseApprovalPolicy.class));
        org.springframework.test.util.ReflectionTestUtils.setField(readers,"events",mock(ExpenseClaimEventRepository.class));
        var policy=new ExpenseClaimAttachmentAccessPolicy(claims);
        org.springframework.test.util.ReflectionTestUtils.setField(policy,"readAccess",readers);
        return policy;
    }
}
