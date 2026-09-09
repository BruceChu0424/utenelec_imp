package com.uten.imp.features.finance;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.bank_transfer.FinanceBankTransfer;
import com.uten.imp.features.finance.expense.FinanceExpense;
import com.uten.imp.features.finance.other_income.FinanceOtherIncome;
import com.uten.imp.features.finance.payment.FinancePayment;
import com.uten.imp.features.finance.receipt.FinanceReceipt;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.CommercialPriceVisibility;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.springframework.aop.support.AopUtils;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Configuration;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.annotation.EnableTransactionManagement;
import org.springframework.transaction.annotation.AnnotationTransactionAttributeSource;
import org.springframework.transaction.TransactionDefinition;

import java.util.HashSet;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class FinanceAttachmentAccessPolicyTest {
    enum Kind { RECEIPT, PAYMENT, EXPENSE, OTHER_INCOME, BANK_TRANSFER }

    @ParameterizedTest @EnumSource(Kind.class)
    void originalFilesRequireBothPageAndFinancialAmountAuthority(Kind kind) {
        var h = new Harness(kind);
        h.permissions.remove("finance:view:all");
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
        h.permissions.add("finance:view:all");
        h.permissions.remove(h.permission("view"));
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
    }

    @ParameterizedTest @EnumSource(Kind.class)
    void scopeAndReadOnlyDelegationRemainAuthoritative(Kind kind) {
        var h = new Harness(kind);
        h.scope(Set.of(h.maker), Set.of());
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
        h.scope(Set.of(), Set.of());
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
        h.maker(null);
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
    }

    @ParameterizedTest @EnumSource(Kind.class)
    void approvedReversedClosedAndUnknownStatusDocumentsStayReadOnly(Kind kind) {
        var h = new Harness(kind);
        for (Short status : new Short[] {1, -1, null}) {
            h.status(status);
            assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
            denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManage(h.id, h.user()));
        }
        h.status((short) 0); h.closed(true);
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManage(h.id, h.user()));
    }

    @ParameterizedTest @EnumSource(Kind.class)
    void editPermissionIsRequiredAndMissingDeletedOwnersNeverLeak(Kind kind) {
        var h = new Harness(kind);
        h.permissions.remove(h.permission("edit"));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(UUID.randomUUID(), h.user()));
        denied(ErrorCode.VALIDATION_FAILED, () -> h.policy.requireCanManage(null, h.user()));
        h.deleted(true);
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
    }

    @ParameterizedTest @EnumSource(Kind.class)
    void confirmAndDeleteLockAndRefreshTheActualDocument(Kind kind) {
        var h = new Harness(kind);
        h.policy.requireCanManageForUpdate(h.id, h.user());
        var sequence = inOrder(h.em);
        sequence.verify(h.em).find(h.entityClass(), h.id);
        sequence.verify(h.em).find(h.entityClass(), h.id, LockModeType.PESSIMISTIC_WRITE);
        sequence.verify(h.em).refresh(h.entity(), LockModeType.PESSIMISTIC_WRITE);
    }

    @ParameterizedTest @EnumSource(Kind.class)
    void approvalWhileWaitingForLockRejectsTheStaleDraft(Kind kind) {
        var h = new Harness(kind);
        doAnswer(invocation -> { h.status((short) 1); return null; })
                .when(h.em).refresh(h.entity(), LockModeType.PESSIMISTIC_WRITE);
        denied(ErrorCode.CONFLICT, () -> h.policy.requireCanManageForUpdate(h.id, h.user()));
    }

    @ParameterizedTest @EnumSource(Kind.class)
    void ownerTransferOrDeletionWhileWaitingForLockIsRechecked(Kind kind) {
        var h = new Harness(kind);
        doAnswer(invocation -> { h.maker(UUID.randomUUID()); return null; })
                .when(h.em).refresh(h.entity(), LockModeType.PESSIMISTIC_WRITE);
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanManageForUpdate(h.id, h.user()));
        h.maker(h.maker);
        doAnswer(invocation -> { h.deleted(true); return null; })
                .when(h.em).refresh(h.entity(), LockModeType.PESSIMISTIC_WRITE);
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanManageForUpdate(h.id, h.user()));
    }

    @Test
    void prepaymentReceiptAlsoRequiresTheOriginalPrepaymentPermission() {
        var h = new Harness(Kind.RECEIPT);
        h.receipt.setReceiptKind(" CUSTOMER_PREPAYMENT ");
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanView(h.id, h.user()));
        h.permissions.add("customer_prepayment:view");
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        assertDoesNotThrow(() -> h.policy.requireCanManage(h.id, h.user()));
    }

    @Test
    void allFivePolicyBeansAreUniqueAndKeepTheOuterTransaction() throws Exception {
        try (var context = new AnnotationConfigApplicationContext()) {
            context.registerBean(EntityManager.class, () -> mock(EntityManager.class));
            context.registerBean(FinanceDocumentAccessPolicy.class, () -> mock(FinanceDocumentAccessPolicy.class));
            context.registerBean(CommercialPriceVisibility.class, () -> mock(CommercialPriceVisibility.class));
            context.registerBean(PlatformTransactionManager.class, () -> mock(PlatformTransactionManager.class));
            context.register(TransactionConfiguration.class, FinanceAttachmentAccessConfiguration.class);
            context.refresh();
            var policies = context.getBeansOfType(AttachmentOwnerAccessPolicy.class);
            assertEquals(5, policies.size());
            Set<String> owners = new HashSet<>();
            var transactionAttributes = new AnnotationTransactionAttributeSource();
            for (var policy : policies.values()) {
                assertTrue(AopUtils.isAopProxy(policy));
                var target = (AttachmentOwnerAccessPolicy) org.springframework.test.util.AopTestUtils.getTargetObject(policy);
                assertTrue(owners.add(target.ownerType()));
                var attribute = transactionAttributes.getTransactionAttribute(
                        target.getClass().getMethod("requireCanManageForUpdate", UUID.class, AuthUser.class),
                        target.getClass());
                assertNotNull(attribute);
                assertEquals(TransactionDefinition.PROPAGATION_MANDATORY, attribute.getPropagationBehavior());
                assertFalse(attribute.isReadOnly());
            }
            assertEquals(Set.of("FINANCE_RECEIPT", "FINANCE_PAYMENT", "FINANCE_EXPENSE",
                    "FINANCE_OTHER_INCOME", "FINANCE_BANK_TRANSFER"), owners);
        }
    }

    @Configuration @EnableTransactionManagement(proxyTargetClass = true)
    static class TransactionConfiguration {}

    private static void denied(ErrorCode expected, org.junit.jupiter.api.function.Executable action) {
        assertEquals(expected, assertThrows(ApiException.class, action).getCode());
    }

    private static class Harness {
        final Kind kind;
        final UUID id = UUID.randomUUID();
        final UUID maker = UUID.randomUUID();
        final EntityManager em = mock(EntityManager.class);
        final OwnerVisibility ownership = mock(OwnerVisibility.class);
        final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        final Set<String> permissions = new HashSet<>();
        final FinanceReceipt receipt = new FinanceReceipt();
        final FinancePayment payment = new FinancePayment();
        final FinanceExpense expense = new FinanceExpense();
        final FinanceOtherIncome income = new FinanceOtherIncome();
        final FinanceBankTransfer transfer = new FinanceBankTransfer();
        final AttachmentOwnerAccessPolicy policy;

        Harness(Kind kind) {
            this.kind = kind;
            permissions.addAll(Set.of(permission("view"), permission("edit"), "finance:view:all"));
            when(current.get()).thenAnswer(ignored -> Optional.of(user()));
            maker(maker); status((short) 0); scope(Set.of(maker), Set.of(maker));
            when(em.find(FinanceReceipt.class, id)).thenReturn(receipt);
            when(em.find(FinancePayment.class, id)).thenReturn(payment);
            when(em.find(FinanceExpense.class, id)).thenReturn(expense);
            when(em.find(FinanceOtherIncome.class, id)).thenReturn(income);
            when(em.find(FinanceBankTransfer.class, id)).thenReturn(transfer);
            when(em.find(FinanceReceipt.class, id, LockModeType.PESSIMISTIC_WRITE)).thenReturn(receipt);
            when(em.find(FinancePayment.class, id, LockModeType.PESSIMISTIC_WRITE)).thenReturn(payment);
            when(em.find(FinanceExpense.class, id, LockModeType.PESSIMISTIC_WRITE)).thenReturn(expense);
            when(em.find(FinanceOtherIncome.class, id, LockModeType.PESSIMISTIC_WRITE)).thenReturn(income);
            when(em.find(FinanceBankTransfer.class, id, LockModeType.PESSIMISTIC_WRITE)).thenReturn(transfer);
            var config = new FinanceAttachmentAccessConfiguration();
            var access = new FinanceDocumentAccessPolicy(ownership, current);
            var prices = new CommercialPriceVisibility(current);
            policy = switch (kind) {
                case RECEIPT -> config.financeReceiptAttachmentAccessPolicy(em, access, prices);
                case PAYMENT -> config.financePaymentAttachmentAccessPolicy(em, access, prices);
                case EXPENSE -> config.financeExpenseAttachmentAccessPolicy(em, access, prices);
                case OTHER_INCOME -> config.financeOtherIncomeAttachmentAccessPolicy(em, access, prices);
                case BANK_TRANSFER -> config.financeBankTransferAttachmentAccessPolicy(em, access, prices);
            };
        }

        String permission(String suffix) { return "finance_" + kind.name().toLowerCase(java.util.Locale.ROOT) + ":" + suffix; }
        AuthUser user() { return new AuthUser(maker, maker, "finance", Set.of(), Set.copyOf(permissions), false, true, false); }
        void scope(Set<UUID> readable, Set<UUID> writable) {
            when(ownership.evaluate(anyString(), anyString())).thenReturn(new OwnerVisibility.OwnerScope(false, readable, writable));
        }
        Object entity() { return switch (kind) { case RECEIPT -> receipt; case PAYMENT -> payment; case EXPENSE -> expense; case OTHER_INCOME -> income; case BANK_TRANSFER -> transfer; }; }
        Class<?> entityClass() { return entity().getClass(); }
        void maker(UUID value) { receipt.setMakerId(value); payment.setMakerId(value); expense.setMakerId(value); income.setMakerId(value); transfer.setMakerId(value); }
        void status(Short value) { receipt.setStatus(value); payment.setStatus(value); expense.setStatus(value); income.setStatus(value); transfer.setStatus(value); }
        void closed(boolean value) { receipt.setClosed(value); payment.setClosed(value); expense.setClosed(value); income.setClosed(value); transfer.setClosed(value); }
        void deleted(boolean value) { receipt.setDeleted(value); payment.setDeleted(value); expense.setDeleted(value); income.setDeleted(value); transfer.setDeleted(value); }
    }
}
