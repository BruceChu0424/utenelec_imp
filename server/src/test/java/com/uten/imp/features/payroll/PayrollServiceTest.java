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
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
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
                new PayrollPdfService(),
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
