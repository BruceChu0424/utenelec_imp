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
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;
import java.util.function.Function;

/** Finance owns file access; original documents may contain amounts that cannot be masked. */
@Configuration(proxyBeanMethods = false)
public class FinanceAttachmentAccessConfiguration {

    @Bean
    AttachmentOwnerAccessPolicy financeReceiptAttachmentAccessPolicy(
            EntityManager em, FinanceDocumentAccessPolicy access, CommercialPriceVisibility prices) {
        return new FinanceFilePolicy<>("FINANCE_RECEIPT", "finance_receipt", "销售收款单",
                FinanceReceipt.class, em, access, prices,
                d -> new DocumentState(d.getMakerId(), d.getStatus(), d.isClosed(), d.isDeleted(),
                        "CUSTOMER_PREPAYMENT".equalsIgnoreCase(d.getReceiptKind() == null
                                ? "" : d.getReceiptKind().trim())));
    }

    @Bean
    AttachmentOwnerAccessPolicy financePaymentAttachmentAccessPolicy(
            EntityManager em, FinanceDocumentAccessPolicy access, CommercialPriceVisibility prices) {
        return new FinanceFilePolicy<>("FINANCE_PAYMENT", "finance_payment", "采购付款单",
                FinancePayment.class, em, access, prices,
                d -> new DocumentState(d.getMakerId(), d.getStatus(), d.isClosed(), d.isDeleted(), false));
    }

    @Bean
    AttachmentOwnerAccessPolicy financeExpenseAttachmentAccessPolicy(
            EntityManager em, FinanceDocumentAccessPolicy access, CommercialPriceVisibility prices) {
        return new FinanceFilePolicy<>("FINANCE_EXPENSE", "finance_expense", "一般费用单",
                FinanceExpense.class, em, access, prices,
                d -> new DocumentState(d.getMakerId(), d.getStatus(), d.isClosed(), d.isDeleted(), false));
    }

    @Bean
    AttachmentOwnerAccessPolicy financeOtherIncomeAttachmentAccessPolicy(
            EntityManager em, FinanceDocumentAccessPolicy access, CommercialPriceVisibility prices) {
        return new FinanceFilePolicy<>("FINANCE_OTHER_INCOME", "finance_other_income", "其它收入单",
                FinanceOtherIncome.class, em, access, prices,
                d -> new DocumentState(d.getMakerId(), d.getStatus(), d.isClosed(), d.isDeleted(), false));
    }

    @Bean
    AttachmentOwnerAccessPolicy financeBankTransferAttachmentAccessPolicy(
            EntityManager em, FinanceDocumentAccessPolicy access, CommercialPriceVisibility prices) {
        return new FinanceFilePolicy<>("FINANCE_BANK_TRANSFER", "finance_bank_transfer", "银行存取款单",
                FinanceBankTransfer.class, em, access, prices,
                d -> new DocumentState(d.getMakerId(), d.getStatus(), d.isClosed(), d.isDeleted(), false));
    }

    private record DocumentState(UUID makerId, Short status, boolean closed, boolean deleted,
                                 boolean customerPrepayment) {}

    /** Each bean has exactly one stable owner type and a compile-time entity mapping. */
    public static class FinanceFilePolicy<T> implements AttachmentOwnerAccessPolicy {
        private final String ownerType;
        private final String permission;
        private final String label;
        private final Class<T> entityClass;
        private final EntityManager em;
        private final FinanceDocumentAccessPolicy access;
        private final CommercialPriceVisibility prices;
        private final Function<T, DocumentState> state;

        FinanceFilePolicy(String ownerType, String permission, String label, Class<T> entityClass,
                                  EntityManager em, FinanceDocumentAccessPolicy access,
                                  CommercialPriceVisibility prices, Function<T, DocumentState> state) {
            this.ownerType = ownerType;
            this.permission = permission;
            this.label = label;
            this.entityClass = entityClass;
            this.em = em;
            this.access = access;
            this.prices = prices;
            this.state = state;
        }

        @Override public String ownerType() { return ownerType; }

        @Override
        @Transactional(readOnly = true)
        public void requireCanView(UUID ownerId, AuthUser user) {
            readable(state.apply(document(ownerId)), user);
        }

        @Override
        @Transactional(readOnly = true)
        public void requireCanManage(UUID ownerId, AuthUser user) {
            editable(state.apply(document(ownerId)), user);
        }

        @Override
        @Transactional(propagation = Propagation.MANDATORY)
        public void requireCanManageForUpdate(UUID ownerId, AuthUser user) {
            // Reject inaccessible objects before waiting for a business-row lock.
            editable(state.apply(document(ownerId)), user);
            T locked = em.find(entityClass, ownerId, LockModeType.PESSIMISTIC_WRITE);
            if (locked == null) throw missing();
            // find may return an already-managed draft: refresh after the lock is essential.
            em.refresh(locked, LockModeType.PESSIMISTIC_WRITE);
            editable(state.apply(locked), user);
        }

        private T document(UUID ownerId) {
            if (ownerId == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请先保存单据再添加文件");
            T document = em.find(entityClass, ownerId);
            if (document == null) throw missing();
            return document;
        }

        private void readable(DocumentState document, AuthUser user) {
            if (document.deleted() || !has(user, permission + ":view")) throw missing();
            access.requireReadable(document.makerId(), label + "不存在");
            if (!prices.canViewFinance()) {
                throw new ApiException(ErrorCode.FORBIDDEN, "财务原件可能包含金额，需要财务金额查看权限");
            }
            if (document.customerPrepayment() && !has(user, "customer_prepayment:view")) {
                throw new ApiException(ErrorCode.FORBIDDEN, "查看该收款原件需要客户预收资金查看权限");
            }
        }

        private void editable(DocumentState document, AuthUser user) {
            readable(document, user);
            if (!has(user, permission + ":edit")) {
                throw new ApiException(ErrorCode.FORBIDDEN, "缺少" + label + "编辑权限");
            }
            access.requireWritable(document.makerId(), "无权修改该" + label + "的文件");
            if (document.status() == null || document.status() != 0 || document.closed()) {
                throw new ApiException(ErrorCode.CONFLICT, "只有未关闭的草稿单据可以添加或删除文件");
            }
        }

        private ApiException missing() { return new ApiException(ErrorCode.NOT_FOUND, label + "不存在"); }

        private static boolean has(AuthUser user, String permission) {
            return user != null && (user.isSuperAdmin() || user.getPermissions().contains(permission));
        }
    }
}
