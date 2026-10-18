package com.uten.imp.features.payroll;

import com.uten.imp.features.notice.HrNoticeService;
import com.uten.imp.application.port.EmployeeNameLookupPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.payroll.dto.PayrollBatchCreateRequest;
import com.uten.imp.features.payroll.dto.PayrollBatchDto;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.mockito.ArgumentCaptor;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.CriteriaQuery;
import jakarta.persistence.criteria.Path;
import jakarta.persistence.criteria.Root;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyCollection;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class PayrollServiceTest {

    private PayrollBatchRepository batchRepository;
    private PayrollSlipRepository slipRepository;
    private PayrollItemRepository itemRepository;
    private PayrollVariableInputRepository variableRepository;
    private PayrollEmployeeQuery employeeQuery;
    private SecurityContextCurrentUser currentUser;
    private TxSessionVars tx;
    private PayrollService service;
    private UUID employeeId;
    private AuthUser authUser;

    @BeforeEach
    void setUp() {
        batchRepository = mock(PayrollBatchRepository.class);
        slipRepository = mock(PayrollSlipRepository.class);
        itemRepository = mock(PayrollItemRepository.class);
        variableRepository = mock(PayrollVariableInputRepository.class);
        employeeQuery = mock(PayrollEmployeeQuery.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        tx = mock(TxSessionVars.class);
        authUser = mock(AuthUser.class);
        employeeId = UUID.randomUUID();

        when(currentUser.get()).thenReturn(Optional.of(authUser));
        when(authUser.isVisitor()).thenReturn(false);
        when(authUser.isSuperAdmin()).thenReturn(false);
        when(authUser.getEmployeeId()).thenReturn(employeeId);

        service = new PayrollService(
                batchRepository,
                slipRepository,
                itemRepository,
                variableRepository,
                employeeQuery,
                currentUser,
                tx,
                new PayrollPdfService(() -> new com.uten.imp.application.port.CompanyBrandingReadPort.Identity(0, "测试公司", List.of())),
                mock(HrNoticeService.class),
                mock(EmployeeNameLookupPort.class));
    }

    @Test
    void selfReaderCannotSeeUnpublishedSlip() {
        when(authUser.getPermissions()).thenReturn(Set.of("payroll:view:self"));
        PayrollSlip slip = slip(employeeId, "PENDING");
        when(slipRepository.findById(slip.getId())).thenReturn(Optional.of(slip));

        ApiException error = assertThrows(ApiException.class, () -> service.getSlip(slip.getId()));

        assertEquals(ErrorCode.NOT_FOUND, error.getCode());
        verify(itemRepository, never()).findBySlipIdInOrderBySlipIdAscLineNoAsc(anyCollection());
    }

    @ParameterizedTest
    @CsvSource({"ACTIVE,PUBLISHED,false", "HISTORY,PUBLISHED,true", "APPROVED,APPROVED,true"})
    @SuppressWarnings({"unchecked", "rawtypes"})
    void batchLifecycleScopeIsAppliedBeforePagingAndPreservesDepartment(
            String scope, String comparedStatus, boolean equality) {
        when(authUser.getPermissions()).thenReturn(Set.of("payroll:review"));
        when(batchRepository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(), PageRequest.of(1, 20), 42));
        UUID departmentId = UUID.randomUUID();
        var response = service.listBatches(null, null, scope, departmentId, 2, 20);
        ArgumentCaptor<Specification<PayrollBatch>> spec = ArgumentCaptor.forClass(Specification.class);
        ArgumentCaptor<Pageable> page = ArgumentCaptor.forClass(Pageable.class);
        verify(batchRepository).findAll(spec.capture(), page.capture());
        Root<PayrollBatch> root = mock(Root.class);
        Path<Object> statusPath = mock(Path.class);
        Path<Object> departmentPath = mock(Path.class);
        when(root.get("status")).thenReturn(statusPath);
        when(root.get("departmentId")).thenReturn(departmentPath);
        CriteriaBuilder cb = mock(CriteriaBuilder.class);
        spec.getValue().toPredicate(root, mock(CriteriaQuery.class), cb);
        if (equality) verify(cb).equal(statusPath, comparedStatus);
        else verify(cb).notEqual(statusPath, comparedStatus);
        verify(cb).equal(departmentPath, departmentId);
        assertEquals(1, page.getValue().getPageNumber());
        assertEquals(42, response.getTotal());
    }

    @Test
    void employeeBehaviorTimestampUsesLockedOwnedPublishedSlip() {
        when(authUser.getPermissions()).thenReturn(Set.of("payroll:view:self"));
        PayrollSlip slip = slip(employeeId, "PUBLISHED");
        when(slipRepository.findByIdForUpdate(slip.getId())).thenReturn(Optional.of(slip));
        when(itemRepository.findBySlipIdInOrderBySlipIdAscLineNoAsc(anyCollection()))
                .thenReturn(List.of());

        var result = service.markViewed(slip.getId());

        assertNotNull(result.viewedAt());
        verify(slipRepository).findByIdForUpdate(slip.getId());
        verify(slipRepository).save(slip);
    }

    @Test
    void generationUsesOnlyExactSnapshotAndVariableAmounts() {
        when(authUser.getPermissions()).thenReturn(Set.of("payroll:generate"));
        UUID departmentId = UUID.randomUUID();
        PayrollEmployeeQuery.Candidate candidate = new PayrollEmployeeQuery.Candidate(
                employeeId, "E001", "员工甲", departmentId, "财务部", "base", "perf", "allowance");
        when(employeeQuery.findCandidates(null)).thenReturn(List.of(candidate));
        when(slipRepository.countActiveConflicts((short) 2026, (short) 7, List.of(employeeId))).thenReturn(0L);
        when(tx.decryptAll(any())).thenReturn(Map.of(
                "base", "100.00", "perf", "20.00", "allowance", "5.00"));

        PayrollVariableInput variable = new PayrollVariableInput();
        variable.setEmployeeId(employeeId);
        variable.setOvertimeAmount(new BigDecimal("10.00"));
        variable.setBonusAmount(new BigDecimal("15.00"));
        variable.setSocialInsuranceAmount(new BigDecimal("7.00"));
        variable.setHousingFundAmount(new BigDecimal("4.00"));
        variable.setTaxAmount(new BigDecimal("2.00"));
        variable.setOtherEarningAmount(new BigDecimal("3.00"));
        variable.setOtherDeductionAmount(new BigDecimal("1.00"));
        when(variableRepository.findForPeriod((short) 2026, (short) 7, List.of(employeeId)))
                .thenReturn(List.of(variable));

        PayrollBatchDto result = service.createBatch(new PayrollBatchCreateRequest(
                2026, 7, null, true, true, true, true));

        assertEquals(new BigDecimal("153.00"), result.grossIncome());
        assertEquals(new BigDecimal("14.00"), result.totalDeduction());
        assertEquals(new BigDecimal("139.00"), result.netIncome());
        assertEquals("DRAFT", result.status());
        assertEquals(1, result.slips().size());
        verify(itemRepository).saveAll(any());
    }

    @Test
    void employeePeriodConflictStopsGenerationBeforeWrites() {
        when(authUser.getPermissions()).thenReturn(Set.of("payroll:generate"));
        PayrollEmployeeQuery.Candidate candidate = new PayrollEmployeeQuery.Candidate(
                employeeId, "E001", "员工甲", UUID.randomUUID(), "财务部",
                null, null, null);
        when(employeeQuery.findCandidates(null)).thenReturn(List.of(candidate));
        when(slipRepository.countActiveConflicts((short) 2026, (short) 7, List.of(employeeId))).thenReturn(1L);

        ApiException error = assertThrows(ApiException.class, () -> service.createBatch(
                new PayrollBatchCreateRequest(2026, 7, null, true, true, true, true)));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        verify(batchRepository, never()).save(any());
    }

    @Test
    @SuppressWarnings("unchecked")
    void sixthPageKeepsTheFiveHundredAndFirstSlip() {
        when(authUser.getPermissions()).thenReturn(Set.of("payroll:view:self"));
        PayrollSlip slip = slip(employeeId, "PUBLISHED");
        PageRequest sixthPage = PageRequest.of(5, 100);
        when(slipRepository.findAll(
                any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(slip), sixthPage, 501));
        when(itemRepository.findBySlipIdInOrderBySlipIdAscLineNoAsc(anyCollection()))
                .thenReturn(List.of());

        var result = service.listSlips(null, null, null, null, 6, 100);

        assertEquals(6, result.getPage());
        assertEquals(100, result.getSize());
        assertEquals(501, result.getTotal());
        assertEquals(6, result.getTotalPages());
        assertEquals(slip.getId(), result.getItems().get(0).id());
    }

    @Test
    @SuppressWarnings("unchecked")
    void unreadAndReadPartitionPublishedOwnedSlipsBeforePagination() {
        when(authUser.getPermissions()).thenReturn(Set.of("payroll:view:self"));
        PayrollSlip unread = slip(employeeId, "PUBLISHED");
        PayrollSlip viewed = slip(employeeId, "PUBLISHED");
        viewed.setViewedAt(Instant.now());
        PayrollSlip directDownload = slip(employeeId, "PUBLISHED");
        directDownload.setDownloadedAt(Instant.now());
        PayrollSlip viewedAndDownloaded = slip(employeeId, "PUBLISHED");
        viewedAndDownloaded.setViewedAt(Instant.now());
        viewedAndDownloaded.setDownloadedAt(Instant.now());
        PayrollSlip inactive = slip(employeeId, "PUBLISHED");
        inactive.setActive(false);
        PayrollSlip unpublished = slip(employeeId, "PENDING");
        unpublished.setViewedAt(Instant.now());
        PayrollSlip otherEmployee = slip(UUID.randomUUID(), "PUBLISHED");
        otherEmployee.setDownloadedAt(Instant.now());
        List<PayrollSlip> fixtures = List.of(
                unread, viewed, directDownload, viewedAndDownloaded,
                inactive, unpublished, otherEmployee);
        when(itemRepository.findBySlipIdInOrderBySlipIdAscLineNoAsc(anyCollection()))
                .thenReturn(List.of());
        when(slipRepository.findAll(any(Specification.class), any(Pageable.class)))
                .thenAnswer(invocation -> {
                    Specification<PayrollSlip> specification = invocation.getArgument(0);
                    Pageable pageable = invocation.getArgument(1);
                    List<PayrollSlip> matching = fixtures.stream()
                            .filter(slip -> matchesSlipSpecification(specification, slip))
                            .toList();
                    List<PayrollSlip> page = matching.stream()
                            .skip(pageable.getOffset()).limit(pageable.getPageSize()).toList();
                    return new PageImpl<>(page, pageable, matching.size());
                });

        Set<UUID> unreadIds = allSlipIds("UNVIEWED");
        Set<UUID> readIds = allSlipIds("VIEWED");
        assertEquals(Set.of(unread.getId()), unreadIds);
        assertEquals(Set.of(viewed.getId(), directDownload.getId(), viewedAndDownloaded.getId()), readIds);
        assertTrue(java.util.Collections.disjoint(unreadIds, readIds));
        Set<UUID> categoryUnion = new HashSet<>(unreadIds);
        categoryUnion.addAll(readIds);
        assertEquals(allSlipIds("PUBLISHED"), categoryUnion);
        assertEquals(Set.of(viewed.getId()), allSlipIds("VIEWED_ONLY"));
        assertEquals(Set.of(directDownload.getId(), viewedAndDownloaded.getId()), allSlipIds("DOWNLOADED"));
    }

    private Set<UUID> allSlipIds(String state) {
        Set<UUID> ids = new HashSet<>();
        var firstPage = service.listSlips(state, null, null, null, 1, 2);
        firstPage.getItems().forEach(item -> ids.add(item.id()));
        for (int page = 2; page <= firstPage.getTotalPages(); page++) {
            var nextPage = service.listSlips(state, null, null, null, page, 2);
            assertEquals(firstPage.getTotal(), nextPage.getTotal());
            nextPage.getItems().forEach(item -> ids.add(item.id()));
        }
        assertEquals(firstPage.getTotal(), ids.size());
        return ids;
    }

    /** Evaluate the service's actual criteria tree against each fixture before taking a page. */
    @SuppressWarnings("unchecked")
    private static boolean matchesSlipSpecification(Specification<PayrollSlip> specification, PayrollSlip slip) {
        Map<Object, Object> values = new HashMap<>();
        Root<PayrollSlip> root = mock(Root.class, invocation -> {
            if (!invocation.getMethod().getName().equals("get")) {
                return org.mockito.Answers.RETURNS_DEFAULTS.answer(invocation);
            }
            Path<Object> path = mock(Path.class);
            Object value = switch (invocation.<String>getArgument(0)) {
                case "active" -> slip.isActive();
                case "employeeId" -> slip.getEmployeeId();
                case "status" -> slip.getStatus();
                case "viewedAt" -> slip.getViewedAt();
                case "downloadedAt" -> slip.getDownloadedAt();
                default -> throw new AssertionError("Unexpected slip field");
            };
            values.put(path, value);
            return path;
        });
        CriteriaBuilder builder = mock(CriteriaBuilder.class, invocation -> {
            String operation = invocation.getMethod().getName();
            List<Object> arguments = new ArrayList<>();
            for (Object argument : invocation.getArguments()) {
                if (argument instanceof Object[] array) arguments.addAll(Arrays.asList(array));
                else arguments.add(argument);
            }
            boolean result = switch (operation) {
                case "isTrue" -> Boolean.TRUE.equals(values.get(arguments.getFirst()));
                case "equal" -> java.util.Objects.equals(values.get(arguments.getFirst()), arguments.get(1));
                case "isNull" -> values.get(arguments.getFirst()) == null;
                case "isNotNull" -> values.get(arguments.getFirst()) != null;
                case "and" -> arguments.stream().allMatch(argument -> Boolean.TRUE.equals(values.get(argument)));
                case "or" -> arguments.stream().anyMatch(argument -> Boolean.TRUE.equals(values.get(argument)));
                default -> throw new AssertionError("Unexpected criteria operation: " + operation);
            };
            jakarta.persistence.criteria.Predicate predicate = mock(jakarta.persistence.criteria.Predicate.class);
            values.put(predicate, result);
            return predicate;
        });
        return Boolean.TRUE.equals(values.get(specification.toPredicate(root, mock(CriteriaQuery.class), builder)));
    }

    private static PayrollSlip slip(UUID employeeId, String status) {
        PayrollSlip slip = new PayrollSlip();
        slip.setEmployeeId(employeeId);
        slip.setEmployeeCodeSnapshot("E001");
        slip.setEmployeeNameSnapshot("员工甲");
        slip.setPayrollYear((short) 2026);
        slip.setPayrollMonth((short) 7);
        slip.setStatus(status);
        slip.setActive(true);
        slip.setGrossIncome(new BigDecimal("100.00"));
        slip.setTotalDeduction(new BigDecimal("10.00"));
        slip.setNetIncome(new BigDecimal("90.00"));
        return slip;
    }
}
