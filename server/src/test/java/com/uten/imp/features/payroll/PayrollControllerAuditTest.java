package com.uten.imp.features.payroll;

import com.uten.imp.audit.AuditService;
import com.uten.imp.features.payroll.dto.PayrollPdf;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.http.ResponseEntity;

import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
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

    private static final class Fixture {
        private final PayrollService service = mock(PayrollService.class);
        private final AuditService audit = mock(AuditService.class);
        private final SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        private final AuthUser actor = mock(AuthUser.class);
        private final UUID actorId = UUID.randomUUID();
        private final PayrollController controller =
                new PayrollController(service, audit, currentUser);

        private Fixture() {
            when(actor.getId()).thenReturn(actorId);
            when(actor.getLoginAccount()).thenReturn("payroll-reader");
            when(currentUser.get()).thenReturn(Optional.of(actor));
        }
    }
}
