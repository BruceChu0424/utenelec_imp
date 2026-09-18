package com.uten.imp.features.finance.receipt;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.accountflow.AccountFlowLedgerService;
import com.uten.imp.features.finance.arap.ArApLedgerRepository;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.features.finance.receivables.FinanceReceiptSourceAllocationService;
import com.uten.imp.features.finance.receipt.dto.FinanceReceiptQueryFilter;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Root;
import org.junit.jupiter.api.Test;
import org.mockito.Answers;
import org.mockito.ArgumentCaptor;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.util.List;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 销售收款单「收款类型」表头筛选（2026-09-16）：receiptKind=按 finance_receipts.receipt_kind
 * 等值（入参大小写不敏感，存储值归一大写）；CUSTOMER_PREPAYMENT 无权限时可见性谓词
 * （notEqual）依旧叠加，筛预收只会得到空集而不是越权。
 */
class FinanceReceiptKindFilterTest {

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void receiptKindFiltersBeforePaginationWithCaseInsensitiveMatch() {
        FinanceReceiptRepository receiptRepo = mock(FinanceReceiptRepository.class);
        when(receiptRepo.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));
        FinanceDocumentAccessPolicy access = mock(FinanceDocumentAccessPolicy.class);
        when(access.scope()).thenReturn(mock(
                OwnerVisibility.OwnerScope.class,
                Answers.RETURNS_DEEP_STUBS));
        // 无 customer_prepayment:view：列表恒叠加 notEqual(CUSTOMER_PREPAYMENT) 兜底。
        when(access.hasAuthority(any(String.class))).thenReturn(false);

        service(receiptRepo, access).list(
                new FinanceReceiptQueryFilter(null, null, null, null,
                        "ar_settlement", null, null),
                1, 20, null, null);

        ArgumentCaptor<Specification<FinanceReceipt>> captor =
                ArgumentCaptor.forClass(Specification.class);
        verify(receiptRepo).findAll(captor.capture(), any(Pageable.class));
        Root<FinanceReceipt> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        captor.getValue().toPredicate(root, null, cb);

        // 小写入参归一成存储值大写再等值；同时保留预收不可见的 notEqual 兜底
        //（receiptKind 列被两处谓词引用：notEqual 预收兜底 + 等值筛选）。
        verify(root, org.mockito.Mockito.times(2)).get("receiptKind");
        verify(cb).equal(any(), eq("AR_SETTLEMENT"));
        verify(cb).notEqual(any(), eq("CUSTOMER_PREPAYMENT"));
    }

    private static FinanceReceiptService service(
            FinanceReceiptRepository receiptRepo, FinanceDocumentAccessPolicy access) {
        return new FinanceReceiptService(
                receiptRepo,
                mock(FinanceReceiptLineRepository.class),
                mock(ArApLedgerRepository.class),
                mock(ArApLedgerService.class),
                mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                mock(EmployeeNameResolver.class),
                mock(EntityManager.class),
                mock(DocNumberService.class),
                access,
                mock(GlPostingService.class),
                mock(FinanceReceiptSourceAllocationService.class),
                mock(AccountFlowLedgerService.class));
    }
}
