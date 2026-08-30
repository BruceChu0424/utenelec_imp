package com.uten.imp.features.payroll;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditService;
import com.uten.imp.features.payroll.dto.PayrollBatchDto;
import com.uten.imp.features.payroll.dto.PayrollPdf;
import com.uten.imp.features.payroll.dto.PayrollSlipDto;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.http.ResponseEntity;

import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class PayrollControllerAuditTest {

    @Test
    void recordsSuccessfulDownloadWithoutPayrollContentOrPii() {
        Fixture fixture = new Fixture();
        UUID slipId = UUID.randomUUID();
        byte[] bytes = new byte[]{1, 2, 3};
        when(fixture.service.downloadSlip(slipId))
                .thenReturn(new PayrollPdf(bytes, "工资条.pdf"));

        ResponseEntity<byte[]> response = fixture.controller.download(slipId);

        assertArrayEquals(bytes, response.getBody());
        verify(fixture.audit).logExplicit(
                fixture.actorId,
                "payroll-reader",
                "download_payroll_slip",
                "payroll_slips",
                slipId.toString(),
                "success");
    }

    @Test
    void auditFailurePreventsDownloadResponseFromBeingReturned() {
        Fixture fixture = new Fixture();
        UUID slipId = UUID.randomUUID();
        when(fixture.service.downloadSlip(slipId))
                .thenReturn(new PayrollPdf(new byte[]{1}, "工资条.pdf"));
        doThrow(new IllegalStateException("audit unavailable"))
                .when(fixture.audit)
                .logExplicit(
                        fixture.actorId,
                        "payroll-reader",
                        "download_payroll_slip",
                        "payroll_slips",
                        slipId.toString(),
                        "success");

        assertThrows(
                IllegalStateException.class,
                () -> fixture.controller.download(slipId));
        verify(fixture.service).downloadSlip(slipId);
    }

    @Test
    void detailViewsRecordOnlyEmployeeCodePeriodAndDepartmentPeriod() {
        Fixture fixture = new Fixture();
        UUID slipId = UUID.randomUUID();
        PayrollSlipDto slip = mock(PayrollSlipDto.class);
        when(slip.employeeCode()).thenReturn("E-001");
        when(slip.year()).thenReturn(2026);
        when(slip.month()).thenReturn(8);
        when(fixture.service.getSlip(slipId)).thenReturn(slip);

        assertSame(slip, fixture.controller.slip(slipId));
        verify(fixture.detailViewAudit).record(
                "view_payroll_slip_detail", "payroll_slips", slipId,
                "E-001 · 2026年8月", null, "工资条");

        UUID batchId = UUID.randomUUID();
        PayrollBatchDto batch = mock(PayrollBatchDto.class);
        when(batch.departmentName()).thenReturn("财务部");
        when(batch.year()).thenReturn(2026);
        when(batch.month()).thenReturn(8);
        when(fixture.service.getBatch(batchId)).thenReturn(batch);

        assertSame(batch, fixture.controller.batch(batchId));
        verify(fixture.detailViewAudit).record(
                "view_payroll_batch_detail", "payroll_batches", batchId,
                "财务部 · 2026年8月", null, "工资批次");
    }

    @Test
    void failedPayrollDetailDoesNotWriteSuccessfulView() {
        Fixture fixture = new Fixture();
        UUID id = UUID.randomUUID();
        RuntimeException failure = new RuntimeException("not readable");
        when(fixture.service.getSlip(id)).thenThrow(failure);

        assertSame(failure, assertThrows(RuntimeException.class,
                () -> fixture.controller.slip(id)));
        verifyNoInteractions(fixture.detailViewAudit);
    }

    private static final class Fixture {
        private final PayrollService service = mock(PayrollService.class);
        private final AuditService audit = mock(AuditService.class);
        private final SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        private final AuditDetailViewRecorder detailViewAudit =
                mock(AuditDetailViewRecorder.class);
        private final AuthUser actor = mock(AuthUser.class);
        private final UUID actorId = UUID.randomUUID();
        private final PayrollController controller =
                new PayrollController(service, audit, currentUser, detailViewAudit);

        private Fixture() {
            when(actor.getId()).thenReturn(actorId);
            when(actor.getLoginAccount()).thenReturn("payroll-reader");
            when(currentUser.get()).thenReturn(Optional.of(actor));
        }
    }
}
