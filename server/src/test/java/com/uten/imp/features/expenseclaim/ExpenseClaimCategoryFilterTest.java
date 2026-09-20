package com.uten.imp.features.expenseclaim;

import com.uten.imp.application.port.HrNoticePort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.finance.EmployeeClaimPostingPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.attachment.AttachmentRepository;
import com.uten.imp.features.attachment.AttachmentService;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimDto;
import com.uten.imp.features.master.account.AccountRepository;
import com.uten.imp.features.master.paymentstyle.PaymentStyleRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.CriteriaQuery;
import jakarta.persistence.criteria.Root;
import jakarta.persistence.criteria.Subquery;
import org.junit.jupiter.api.Test;
import org.mockito.Answers;
import org.mockito.ArgumentCaptor;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.RETURNS_DEEP_STUBS;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 我的报销「类别」表头筛选（2026-09-16）：类别挂在明细项上，筛类别 = 存在命中类别的
 * 明细行（Specification EXISTS 子查询）；类别白名单 fail-closed；facets 增类别桶
 * （expense_claim_items 按类别聚合，见 ExpenseApplicantQueryCategoryFacetsTest）。
 */
class ExpenseClaimCategoryFilterTest {

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void categoryFiltersThroughItemExistsSubquery() {
        var repo = mock(ExpenseClaimRepository.class);
        when(repo.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));
        var currentUser = mock(SecurityContextCurrentUser.class);
        UUID employeeId = UUID.randomUUID();
        when(currentUser.get()).thenReturn(Optional.of(new AuthUser(
                UUID.randomUUID(), employeeId, "tester",
                Set.of(), Set.of("expense:apply"), false, true, false)));
        ExpenseClaimService service = service(repo, currentUser);

        PageResponse<ExpenseClaimDto> page = service.listMine(
                null, null, null, null, "TRANSPORT", 1, 20);
        org.assertj.core.api.Assertions.assertThat(page.getItems()).isEmpty();

        ArgumentCaptor<Specification<ExpenseClaim>> captor =
                ArgumentCaptor.forClass(Specification.class);
        verify(repo).findAll(captor.capture(), any(Pageable.class));
        CriteriaQuery<?> query = mock(CriteriaQuery.class, RETURNS_DEEP_STUBS);
        Subquery sub = mock(Subquery.class, RETURNS_DEEP_STUBS);
        when(query.subquery(UUID.class)).thenReturn(sub);
        Root<ExpenseClaim> root = mock(Root.class, RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, RETURNS_DEEP_STUBS);
        captor.getValue().toPredicate(root, query, cb);

        // 存在性子查询：明细 category 等值 + 主单 id IN 子查询。
        verify(sub).from(ExpenseClaimItem.class);
        verify(cb).equal(any(), eq("TRANSPORT"));
        verify(sub).select(any());
    }

    @Test
    void unknownCategoryFailsClosed() {
        var repo = mock(ExpenseClaimRepository.class);
        var currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.get()).thenReturn(Optional.of(new AuthUser(
                UUID.randomUUID(), UUID.randomUUID(), "tester",
                Set.of(), Set.of("expense:apply"), false, true, false)));
        ExpenseClaimService service = service(repo, currentUser);

        assertThatThrownBy(() -> service.listMine(
                null, null, null, null, "GIFTS", 1, 20))
                .isInstanceOf(ApiException.class);
    }

    private static ExpenseClaimService service(
            ExpenseClaimRepository repo, SecurityContextCurrentUser currentUser) {
        return new ExpenseClaimService(
                repo,
                mock(ExpenseClaimItemRepository.class),
                mock(ExpenseClaimInvoiceRepository.class),
                mock(ExpenseClaimEventRepository.class),
                new ExpenseApplicantQuery(mock(EntityManager.class)),
                mock(EmployeeClaimPostingPort.class),
                currentUser,
                mock(TxSessionVars.class),
                mock(EntityManager.class),
                mock(TaskClaimService.class),
                mock(AttachmentRepository.class),
                mock(AttachmentService.class),
                mock(HrNoticePort.class),
                mock(DocNumberService.class),
                mock(com.uten.imp.application.port.PaymentReferenceLabelsPort.class), mock(ExpenseClaimSettingsService.class));
    }
}
