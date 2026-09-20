package com.uten.imp.features.expenseclaim;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.notice.HrNoticeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.finance.EmployeeClaimPostingPort;
import com.uten.imp.common.finance.EmployeeClaimPostingPort.EmployeeClaimPosting;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimBatchRequest;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimCreateRequest;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimInvoiceInput;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimItemInput;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimPaymentRequest;
import com.uten.imp.features.attachment.AttachmentRepository;
import com.uten.imp.features.attachment.AttachmentLifecycleState;
import com.uten.imp.features.attachment.AttachmentService;
import com.uten.imp.application.port.PaymentReferenceLabelsPort;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.InOrder;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ExpenseClaimServiceTest {

    private ExpenseClaimRepository claimRepository;
    private ExpenseClaimItemRepository itemRepository;
    private ExpenseClaimInvoiceRepository invoiceRepository;
    private ExpenseClaimEventRepository eventRepository;
    private ExpenseApplicantQuery applicantQuery;
    private EmployeeClaimPostingPort postingPort;
    private SecurityContextCurrentUser currentUser;
    private com.uten.imp.features.common.taskclaim.TaskClaimService taskClaim;
    private AttachmentRepository attachmentRepository;
    private AttachmentService attachmentService;
    private DocNumberService docNumber;
    private PaymentReferenceLabelsPort paymentLabels;
    private EntityManager em;
    private ExpenseClaimSettingsService settings;
    private HrNoticeService notices;
    private Query hierarchyLock;
    private ExpenseClaimService service;
    private AuthUser authUser;
    private UUID actorId;

    @BeforeEach
    void setUp() {
        claimRepository = mock(ExpenseClaimRepository.class);
        itemRepository = mock(ExpenseClaimItemRepository.class);
        invoiceRepository = mock(ExpenseClaimInvoiceRepository.class);
        eventRepository = mock(ExpenseClaimEventRepository.class);
        applicantQuery = mock(ExpenseApplicantQuery.class);
        postingPort = mock(EmployeeClaimPostingPort.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        taskClaim = mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class);
        attachmentRepository = mock(AttachmentRepository.class);
        attachmentService = mock(AttachmentService.class);
        docNumber = mock(DocNumberService.class);
        paymentLabels = mock(PaymentReferenceLabelsPort.class);
        when(paymentLabels.resolve(any(),any())).thenReturn(PaymentReferenceLabelsPort.Labels.EMPTY);
        notices=mock(HrNoticeService.class);
        settings=mock(ExpenseClaimSettingsService.class);
        when(settings.get()).thenReturn(new com.uten.imp.features.expenseclaim.dto.ExpenseClaimSettingsDto("公司",null,null,false,0L));
        em = mock(EntityManager.class);
        Query invoiceLock=mock(Query.class);
        when(em.createNativeQuery(contains("hashtextextended"))).thenReturn(invoiceLock);
        when(invoiceLock.setParameter(anyString(),any())).thenReturn(invoiceLock);
        when(attachmentRepository.findByOwnerTypeAndOwnerIdAndLifecycleStateOrderByCreatedAtAsc(anyString(),any(),any()))
                .thenReturn(List.of(new com.uten.imp.features.attachment.Attachment()));
        hierarchyLock = mock(Query.class);
        when(em.createNativeQuery(contains("PAYMENT_STYLE_HIERARCHY")))
                .thenReturn(hierarchyLock);
        authUser = mock(AuthUser.class);
        actorId = UUID.randomUUID();

        when(currentUser.get()).thenReturn(Optional.of(authUser));
        when(authUser.isVisitor()).thenReturn(false);
        when(authUser.isSuperAdmin()).thenReturn(false);
        when(authUser.getEmployeeId()).thenReturn(actorId);
        when(authUser.getUsername()).thenReturn("actor-login");
        when(docNumber.nextNumber(DocNumberPrefix.EXPENSE_CLAIM))
                .thenReturn("BX20260919000001");

        service = new ExpenseClaimService(
                claimRepository,
                itemRepository,
                invoiceRepository,
                eventRepository,
                applicantQuery,
                postingPort,
                currentUser,
                mock(TxSessionVars.class),
                em,
                taskClaim,
                attachmentRepository,
                attachmentService,
                notices,
                docNumber,
                paymentLabels,settings);
    }

    @Test
    void createCalculatesTotalOnServer() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        when(applicantQuery.findEligible(actorId)).thenReturn(Optional.of(
                new ExpenseApplicantQuery.ApplicantSnapshot("员工甲", UUID.randomUUID())));

        var result = service.create(new ExpenseClaimCreateRequest(
                "差旅报销",
                null,
                List.of(
                        new ExpenseClaimItemInput(
                                "travel", new BigDecimal("12.30"), LocalDate.now(), "住宿"),
                        new ExpenseClaimItemInput(
                                "MEAL", new BigDecimal("7.70"), LocalDate.now(), "餐费"))));

        assertEquals(new BigDecimal("20.00"), result.totalAmount());
        assertEquals("DRAFT", result.status());
        assertEquals(2, result.items().size());
        assertEquals("BX20260919000001", result.claimNo());
        verify(itemRepository).saveAll(any());
    }

    @Test
    void createRecordsCreatedEventWithActorSnapshot() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        when(applicantQuery.findEligible(actorId)).thenReturn(Optional.of(
                new ExpenseApplicantQuery.ApplicantSnapshot("员工甲", UUID.randomUUID())));
        when(applicantQuery.employeeNames(List.of(actorId)))
                .thenReturn(java.util.Map.of(actorId, "审批人"));

        service.create(new ExpenseClaimCreateRequest(
                "差旅报销", null,
                List.of(new ExpenseClaimItemInput(
                        "MEAL", new BigDecimal("7.70"), LocalDate.now(), null))));

        ArgumentCaptor<ExpenseClaimEvent> captor =
                ArgumentCaptor.forClass(ExpenseClaimEvent.class);
        verify(eventRepository).save(captor.capture());
        assertEquals("CREATED", captor.getValue().getEventType());
        assertEquals("审批人", captor.getValue().getActorNameSnapshot());
    }

    @Test
    void editReplacesItemsAndKeepsRejectedStatusForRework() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        ExpenseClaim claim = claim(actorId, "REJECTED");
        claim.setRejectReason("票据不全");
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        when(itemRepository.findByClaimIdInOrderByClaimIdAscLineNoAsc(any()))
                .thenReturn(List.of());

        var result = service.edit(claim.getId(), new ExpenseClaimCreateRequest(
                "差旅报销（修订）", "补齐票据",
                List.of(new ExpenseClaimItemInput(
                        "TRAVEL", new BigDecimal("300.00"), LocalDate.now(), "住宿"))));

        assertEquals("REJECTED", result.status());
        assertEquals(new BigDecimal("300.00"), result.totalAmount());
        verify(itemRepository).deleteByClaimId(claim.getId());
        verify(itemRepository).saveAll(any());
    }

    @Test
    void editRejectsClaimAlreadyInApprovalFlow() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        ExpenseClaim claim = claim(actorId, "SUBMITTED");
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));

        ApiException error = assertThrows(ApiException.class, () -> service.edit(
                claim.getId(),
                new ExpenseClaimCreateRequest("改", null, List.of(
                        new ExpenseClaimItemInput(
                                "MEAL", BigDecimal.ONE, LocalDate.now(), null)))));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        verify(itemRepository, never()).deleteByClaimId(any());
    }

    @Test
    void submitAcceptsRejectedClaimAndClearsRejectionTrace() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        ExpenseClaim claim = claim(actorId, "REJECTED");
        claim.setRejectReason("票据不全");
        claim.setRejectedBy(UUID.randomUUID());
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        when(itemRepository.findByClaimIdInOrderByClaimIdAscLineNoAsc(any()))
                .thenAnswer(invocation -> { List<UUID> ids = invocation.getArgument(0); return ids.stream().map(ExpenseClaimServiceTest::evidenceItem).toList(); });

        var result = service.submit(claim.getId());

        assertEquals("SUBMITTED", result.status());
        assertNull(claim.getRejectReason());
        assertNull(claim.getRejectedBy());
        ArgumentCaptor<ExpenseClaimEvent> captor =
                ArgumentCaptor.forClass(ExpenseClaimEvent.class);
        verify(eventRepository).save(captor.capture());
        assertEquals("SUBMITTED", captor.getValue().getEventType());
        assertEquals("驳回后重新提交", captor.getValue().getRemark());
    }

    @Test
    void submitRejectsPaidClaim() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        ExpenseClaim claim = claim(actorId, "PAID");
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));

        ApiException error = assertThrows(ApiException.class,
                () -> service.submit(claim.getId()));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
    }

    @Test
    void approveRecordsApprovalEvent() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:approve","attachment:view","attachment:download"));
        ExpenseClaim claim = claim(UUID.randomUUID(), "SUBMITTED");
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        when(itemRepository.findByClaimIdInOrderByClaimIdAscLineNoAsc(any()))
                .thenAnswer(invocation -> { List<UUID> ids = invocation.getArgument(0); return ids.stream().map(ExpenseClaimServiceTest::evidenceItem).toList(); });

        service.approve(claim.getId());

        ArgumentCaptor<ExpenseClaimEvent> captor =
                ArgumentCaptor.forClass(ExpenseClaimEvent.class);
        verify(eventRepository).save(captor.capture());
        assertEquals("APPROVED", captor.getValue().getEventType());
        assertEquals(actorId, captor.getValue().getActorEmployeeId());
    }

    @Test
    void approveBatchDecidesEveryClaimInStableOrder() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:approve","attachment:view","attachment:download"));
        ExpenseClaim first = claim(UUID.randomUUID(), "SUBMITTED");
        ExpenseClaim second = claim(UUID.randomUUID(), "SUBMITTED");
        when(claimRepository.findByIdForUpdate(first.getId())).thenReturn(Optional.of(first));
        when(claimRepository.findByIdForUpdate(second.getId())).thenReturn(Optional.of(second));
        when(itemRepository.findByClaimIdInOrderByClaimIdAscLineNoAsc(any()))
                .thenAnswer(invocation -> { List<UUID> ids = invocation.getArgument(0); return ids.stream().map(ExpenseClaimServiceTest::evidenceItem).toList(); });

        UUID low = first.getId().compareTo(second.getId()) < 0 ? first.getId() : second.getId();
        UUID high = first.getId().compareTo(second.getId()) < 0 ? second.getId() : first.getId();
        var result = service.approveBatch(new ExpenseClaimBatchRequest(
                List.of(high, low, low), null));

        assertEquals(2, result.processed());
        InOrder order = inOrder(claimRepository);
        order.verify(claimRepository).findByIdForUpdate(low);
        order.verify(claimRepository).findByIdForUpdate(high);
        assertEquals("APPROVED", first.getStatus());
        assertEquals("APPROVED", second.getStatus());
    }

    @Test
    void rejectBatchRequiresReason() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:approve"));

        ApiException error = assertThrows(ApiException.class, () -> service.rejectBatch(
                new ExpenseClaimBatchRequest(List.of(UUID.randomUUID()), "  ")));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        verifyNoInteractions(claimRepository);
    }

    @Test
    void applicantCannotApproveOwnClaim() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        ExpenseClaim claim = claim(actorId, "SUBMITTED");
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));

        ApiException error = assertThrows(ApiException.class, () -> service.approve(claim.getId()));

        assertEquals(ErrorCode.FORBIDDEN, error.getCode());
        verify(claimRepository, never()).save(any());
    }

    @Test
    void applicantCannotPayOwnClaim() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:pay"));
        ExpenseClaim claim = claim(actorId, "APPROVED");
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));

        ApiException error = assertThrows(ApiException.class, () -> service.pay(
                claim.getId(), payment()));

        assertEquals(ErrorCode.FORBIDDEN, error.getCode());
        verify(postingPort, never()).postEmployeeClaim(any());
    }

    @Test
    void paidRetryWithSameParametersIsIdempotent() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:pay"));
        ExpenseClaimPaymentRequest payment = payment();
        ExpenseClaim claim = claim(UUID.randomUUID(), "PAID");
        claim.setPaymentAccountId(payment.accountId());
        claim.setPaymentExpenseStyleId(payment.expenseStyleId());
        claim.setPaymentDate(payment.paymentDate());
        claim.setFinanceExpenseId(UUID.randomUUID());
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        when(itemRepository.findByClaimIdInOrderByClaimIdAscLineNoAsc(any()))
                .thenReturn(List.of());

        var result = service.pay(claim.getId(), payment);

        assertEquals("PAID", result.status());
        verify(postingPort, never()).postEmployeeClaim(any());
        verify(claimRepository, never()).save(any());
    }

    @Test
    void approvedPaymentPostsFinanceThenMarksClaimPaid() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:pay"));
        ExpenseClaim claim = claim(UUID.randomUUID(), "APPROVED");
        ExpenseClaimPaymentRequest payment = payment();
        UUID financeExpenseId = UUID.randomUUID();
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        when(postingPort.postEmployeeClaim(any(EmployeeClaimPosting.class)))
                .thenReturn(financeExpenseId);
        when(itemRepository.findByClaimIdInOrderByClaimIdAscLineNoAsc(any()))
                .thenReturn(List.of());

        var result = service.pay(claim.getId(), payment);

        assertEquals("PAID", result.status());
        assertEquals(financeExpenseId, claim.getFinanceExpenseId());
        verify(postingPort).postEmployeeClaim(any(EmployeeClaimPosting.class));
        verify(claimRepository).save(claim);
        InOrder order = inOrder(em, hierarchyLock, claimRepository);
        order.verify(em).createNativeQuery(contains("PAYMENT_STYLE_HIERARCHY"));
        order.verify(hierarchyLock).getSingleResult();
        order.verify(claimRepository).findByIdForUpdate(claim.getId());
    }

    @Test
    void postingFailureDoesNotMarkClaimPaid() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:pay"));
        ExpenseClaim claim = claim(UUID.randomUUID(), "APPROVED");
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        when(postingPort.postEmployeeClaim(any(EmployeeClaimPosting.class)))
                .thenThrow(new IllegalStateException("posting failed"));

        assertThrows(IllegalStateException.class, () -> service.pay(claim.getId(), payment()));

        assertEquals("APPROVED", claim.getStatus());
        verify(claimRepository, never()).save(any());
    }

    @Test
    void approverCannotReadSomeoneElsesDraft() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        ExpenseClaim claim = claim(UUID.randomUUID(), "DRAFT");
        when(claimRepository.findById(claim.getId())).thenReturn(Optional.of(claim));

        ApiException error = assertThrows(ApiException.class, () -> service.detail(claim.getId()));

        assertEquals(ErrorCode.NOT_FOUND, error.getCode());
    }

    @Test
    void detailWithoutAttachmentViewNeverIssuesDownloadCapabilities() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        ExpenseClaim claim = claim(actorId, "DRAFT");
        when(claimRepository.findById(claim.getId())).thenReturn(Optional.of(claim));
        when(itemRepository.findByClaimIdInOrderByClaimIdAscLineNoAsc(any()))
                .thenReturn(List.of());

        var detail = service.detail(claim.getId());

        assertEquals(List.of(), detail.attachments());
        verifyNoInteractions(attachmentService);
    }

    @Test
    void detailWithAttachmentViewDelegatesToCentralOwnerPolicy() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply", "attachment:view"));
        ExpenseClaim claim = claim(actorId, "DRAFT");
        when(claimRepository.findById(claim.getId())).thenReturn(Optional.of(claim));
        when(itemRepository.findByClaimIdInOrderByClaimIdAscLineNoAsc(any()))
                .thenReturn(List.of());
        when(attachmentService.list("EXPENSE_CLAIM", claim.getId())).thenReturn(List.of());

        service.detail(claim.getId());

        verify(attachmentService).list("EXPENSE_CLAIM", claim.getId());
    }

    @Test
    void detailResolvesApplicantDepartmentNameFromSnapshotId() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        ExpenseClaim claim = claim(actorId, "DRAFT");
        when(claimRepository.findById(claim.getId())).thenReturn(Optional.of(claim));
        when(itemRepository.findByClaimIdInOrderByClaimIdAscLineNoAsc(any()))
                .thenReturn(List.of());
        when(applicantQuery.departmentNames(List.of(claim.getApplicantDepartmentId())))
                .thenReturn(java.util.Map.of(claim.getApplicantDepartmentId(), "研发部"));

        var detail = service.detail(claim.getId());

        assertEquals(claim.getApplicantDepartmentId(), detail.departmentId());
        assertEquals("研发部", detail.departmentName());
    }

    @Test
    void pendingFacetsAggregateDepartmentsAndMonthsForApprovalStatuses() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        UUID departmentId = UUID.randomUUID();
        when(applicantQuery.departmentFacets(Set.of("SUBMITTED", "REVIEWING"),actorId,false))
                .thenReturn(List.of(new ExpenseApplicantQuery.FacetRow(
                        departmentId.toString(), "研发部", 3)));
        when(applicantQuery.monthFacets(Set.of("SUBMITTED", "REVIEWING"),actorId,false))
                .thenReturn(List.of(new ExpenseApplicantQuery.FacetRow("2026-09", "2026-09", 3)));

        var facets = service.facets("pending");

        assertEquals(1, facets.departments().size());
        assertEquals(departmentId.toString(), facets.departments().get(0).value());
        assertEquals("研发部", facets.departments().get(0).label());
        assertEquals(3L, facets.departments().get(0).count());
        assertEquals("2026-09", facets.months().get(0).value());
        assertEquals(3L, facets.months().get(0).count());
    }

    @Test
    void payableFacetsRequirePayPermission() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:approve"));

        ApiException error = assertThrows(ApiException.class, () -> service.facets("payable"));

        assertEquals(ErrorCode.FORBIDDEN, error.getCode());
        verifyNoInteractions(applicantQuery);
    }

    @Test
    void facetsRejectUnknownQueue() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:approve", "expense:pay"));

        ApiException error = assertThrows(ApiException.class, () -> service.facets("mine"));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
    }

    // ---- 发票登记（V608） ---------------------------------------------------------

    @Test
    void addInvoiceAcceptsDigitalInvoiceWithoutCode() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        ExpenseClaim claim = claim(actorId, "DRAFT");
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        when(itemRepository.findByClaimIdInOrderByClaimIdAscLineNoAsc(any()))
                .thenReturn(List.of());

        service.addInvoice(claim.getId(), invoice("24312000000012345678", null));

        ArgumentCaptor<ExpenseClaimInvoice> captor =
                ArgumentCaptor.forClass(ExpenseClaimInvoice.class);
        verify(invoiceRepository).saveAndFlush(captor.capture());
        assertEquals("DIGITAL", captor.getValue().getInvoiceType());
        assertEquals("24312000000012345678", captor.getValue().getInvoiceNo());
        assertNull(captor.getValue().getInvoiceCode());
    }

    @Test
    void addInvoiceRequiresCodeForLegacyEightDigitNumber() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        ExpenseClaim claim = claim(actorId, "DRAFT");
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));

        ApiException error = assertThrows(ApiException.class, () ->
                service.addInvoice(claim.getId(), invoice("12345678", null)));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        verify(invoiceRepository, never()).save(any());
    }

    @Test
    void addInvoiceRejectsDuplicateAcrossLiveClaims() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        ExpenseClaim claim = claim(actorId, "DRAFT");
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        when(invoiceRepository.duplicateInvoice("24312000000012345678",null,null,"")).thenReturn(Optional.of(UUID.randomUUID()));

        ApiException error = assertThrows(ApiException.class, () ->
                service.addInvoice(claim.getId(), invoice("24312000000012345678", null)));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        org.assertj.core.api.Assertions
                .assertThat(error.getMessage()).contains("不能重复报销");
        verify(invoiceRepository, never()).save(any());
    }

    @Test
    void addInvoiceBlocksClaimsAlreadyInApprovalFlow() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        ExpenseClaim claim = claim(actorId, "SUBMITTED");
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));

        ApiException error = assertThrows(ApiException.class, () ->
                service.addInvoice(claim.getId(), invoice("24312000000012345678", null)));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        verify(invoiceRepository, never()).save(any());
    }

    @Test
    void invoiceAmountMismatchMarksCheckStateForReviewer() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        ExpenseClaim claim = claim(actorId, "DRAFT");
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        when(itemRepository.findByClaimIdInOrderByClaimIdAscLineNoAsc(any()))
                .thenReturn(List.of());

        service.addInvoice(claim.getId(), new ExpenseClaimInvoiceInput(
                "DIGITAL", null, "24312000000012345678",
                LocalDate.now(), "某酒店", "91310000MA1FL8XX00", "上海优腾",
                new BigDecimal("80.00"), new BigDecimal("20.00"),
                new BigDecimal("90.00"), null, null));

        ArgumentCaptor<ExpenseClaimInvoice> captor =
                ArgumentCaptor.forClass(ExpenseClaimInvoice.class);
        verify(invoiceRepository).saveAndFlush(captor.capture());
        assertEquals("MISMATCH", captor.getValue().getCheckState());
    }

    @Test
    void summaryRequiresApproveOrPayPermission() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));

        ApiException error = assertThrows(ApiException.class, () -> service.summary());

        assertEquals(ErrorCode.FORBIDDEN, error.getCode());
    }


    @Test void rejectionResolvesPreviousTaskBeforePublishingApplicantsCorrectionTask() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        var claim=claim(UUID.randomUUID(),"SUBMITTED");
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        service.reject(claim.getId(),"补充原件");
        var order=inOrder(notices);order.verify(notices).resolveExpenseClaim(claim.getId(),"REJECTED");
        order.verify(notices).notifyExpenseClaimRejected(claim.getId(),claim.getApplicantNameSnapshot(),"补充原件",null);
    }

    @Test void approvedClaimCannotBeMarkedPaidWithoutPaymentEvidence() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:pay"));
        var claim=claim(UUID.randomUUID(),"APPROVED");
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        when(attachmentRepository.findByOwnerTypeAndOwnerIdAndLifecycleStateOrderByCreatedAtAsc(
            "EXPENSE_PAYMENT_PROOF",claim.getId(),AttachmentLifecycleState.CLEAN)).thenReturn(List.of());
        assertEquals(ErrorCode.VALIDATION_FAILED,assertThrows(ApiException.class,()->service.pay(claim.getId(),payment())).getCode());
        verify(postingPort,never()).postEmployeeClaim(any());
    }

    @Test void relabelingAStandardDigitalInvoiceAsOtherCannotBypassDeduplication() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        var claim=claim(actorId,"DRAFT");when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        when(invoiceRepository.duplicateInvoice("26310000000000000001",null,null,"")).thenReturn(Optional.of(UUID.randomUUID()));
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->service.addInvoice(claim.getId(),
            new ExpenseClaimInvoiceInput("OTHER",null,"26310000000000000001",LocalDate.now(),"开具单位",null,null,
                null,null,new BigDecimal("10.00"),null,null))).getCode());
    }

    @Test void anotherApplicantsDraftIsNotExposedThroughAStaleVersionError() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        var claim=claim(UUID.randomUUID(),"DRAFT");claim.setVersion(7);
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        assertEquals(ErrorCode.NOT_FOUND,assertThrows(ApiException.class,()->service.submit(claim.getId(),0L)).getCode());
        verify(eventRepository,never()).save(any());
    }

    @Test void staleVersionCannotApproveAWithdrawnAndResubmittedRevision() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        var claim=claim(UUID.randomUUID(),"SUBMITTED");claim.setVersion(3);
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->service.approve(claim.getId(),1L)).getCode());
        assertEquals("SUBMITTED",claim.getStatus());verify(eventRepository,never()).save(any());
    }
    @Test void invoiceArithmeticMatchDoesNotPretendToBeTaxVerification() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        var claim=claim(actorId,"DRAFT");when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        service.addInvoice(claim.getId(),invoice("26310000000000000001",null));
        var captor=ArgumentCaptor.forClass(ExpenseClaimInvoice.class);verify(invoiceRepository).saveAndFlush(captor.capture());
        assertEquals("AMOUNTS_MATCH",captor.getValue().getCheckState());assertNull(captor.getValue().getVerifiedBy());
    }
    @Test void invoiceNumberWithLettersIsRejectedRatherThanSilentlyRewritten() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        var claim=claim(actorId,"DRAFT");when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        assertThrows(ApiException.class,()->service.addInvoice(claim.getId(),invoice("2631000000000000000X",null)));
        verify(invoiceRepository,never()).saveAndFlush(any());
    }
    @Test void sameClaimDuplicateInvoiceAlsoFailsBeforeDatabaseUniqueViolation() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        var claim=claim(actorId,"DRAFT");when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        when(invoiceRepository.duplicateInvoice("26310000000000000001",null,null,"")).thenReturn(Optional.of(UUID.randomUUID()));
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->service.addInvoice(claim.getId(),invoice("26310000000000000001",null))).getCode());
    }
    @Test void approvalActorCannotDisburseEvenWithPayPermission() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:pay"));
        var claim=claim(UUID.randomUUID(),"APPROVED");claim.setApprovedBy(actorId);
        when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        assertEquals(ErrorCode.FORBIDDEN,assertThrows(ApiException.class,()->service.pay(claim.getId(),payment())).getCode());
        verify(postingPort,never()).postEmployeeClaim(any());
    }
    @Test void summaryDoesNotQueryOrRevealUnauthorizedPaymentAmounts() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:approve"));
        when(claimRepository.aggregateActionable(Set.of("SUBMITTED","REVIEWING"),actorId,false))
            .thenReturn(new Object[]{new Object[]{2L,new BigDecimal("123.00")}});
        var result=service.summary();assertEquals(2,result.pendingCount());
        assertEquals(new BigDecimal("123.00"),result.pendingAmount());assertEquals(0,result.payableCount());
        verify(claimRepository,never()).aggregateActionable(Set.of("APPROVED"),actorId,true);
        verify(claimRepository,never()).aggregatePaidBetween(any(),any());
    }
    @Test void missingOriginalBlocksSubmissionWithoutChangingStateOrNotifying() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        var claim=claim(actorId,"DRAFT");when(claimRepository.findByIdForUpdate(claim.getId())).thenReturn(Optional.of(claim));
        when(itemRepository.findByClaimIdInOrderByClaimIdAscLineNoAsc(any())).thenAnswer(invocation -> { List<UUID> ids = invocation.getArgument(0); return ids.stream().map(ExpenseClaimServiceTest::evidenceItem).toList(); });
        when(attachmentRepository.findByOwnerTypeAndOwnerIdAndLifecycleStateOrderByCreatedAtAsc(anyString(),any(),any())).thenReturn(List.of());
        assertThrows(ApiException.class,()->service.submit(claim.getId()));assertEquals("DRAFT",claim.getStatus());
        verify(eventRepository,never()).save(any());
    }
    @Test void precheckNeverLeaksSomeoneElsesApplicantAndClaimNumber() {
        when(authUser.getPermissions()).thenReturn(Set.of("expense:apply"));
        when(invoiceRepository.findDuplicateHolder("26310000000000000001",null,null,""))
            .thenReturn(Optional.of(new Object[]{UUID.randomUUID(),"PRIVATE","DRAFT","PRIVATE"}));
        var result=service.checkInvoiceDuplicate("26310000000000000001",null,null);
        assertEquals(true,result.duplicated());assertNull(result.heldByClaimNo());assertNull(result.heldByApplicantName());
    }

    private static ExpenseClaimInvoiceInput invoice(String invoiceNo, String code) {
        return new ExpenseClaimInvoiceInput(
                invoiceNo != null && invoiceNo.length() == 20 ? "DIGITAL" : "PAPER_GENERAL",
                code, invoiceNo,
                LocalDate.now(), "某酒店", "91310000MA1FL8XX00", "上海优腾",
                new BigDecimal("80.00"), new BigDecimal("10.00"),
                new BigDecimal("90.00"), null, null);
    }

    private static ExpenseClaimItem evidenceItem() {
        var item=new ExpenseClaimItem(); item.setClaimId(UUID.randomUUID()); item.setCategory("TRAVEL");item.setExpenseDate(LocalDate.now());
        item.setAmount(new BigDecimal("100.00"));item.setDescription("住宿费用");return item;
    }

    private static ExpenseClaimItem evidenceItem(UUID claimId) {
        ExpenseClaimItem item = evidenceItem();
        item.setClaimId(claimId);
        return item;
    }

    private static ExpenseClaim claim(UUID applicantId, String status) {
        ExpenseClaim claim = new ExpenseClaim();
        claim.setApplicantId(applicantId);
        claim.setApplicantNameSnapshot("员工甲");
        claim.setApplicantDepartmentId(UUID.randomUUID());
        claim.setClaimNo("BX20260919000001");
        claim.setTitle("差旅报销");
        claim.setRemark("合法凭证及业务证明见附件");
        claim.setTotalAmount(new BigDecimal("100.00"));
        claim.setStatus(status);
        return claim;
    }

    private static ExpenseClaimPaymentRequest payment() {
        return new ExpenseClaimPaymentRequest(
                UUID.randomUUID(), UUID.randomUUID(), LocalDate.now());
    }
}
