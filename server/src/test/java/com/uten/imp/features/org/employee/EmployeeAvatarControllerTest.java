package com.uten.imp.features.org.employee;

import com.uten.imp.application.port.AttachmentAccessPort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.admin.UserAccountAdminService;
import com.uten.imp.responsibility.DataHandoverService;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpHeaders;

import java.io.ByteArrayInputStream;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoMoreInteractions;
import static org.mockito.Mockito.when;

class EmployeeAvatarControllerTest {
    @Test
    void selectedAvatarReturnsOriginalBytesThroughPrivateResponseAndNeverListsDocuments() throws Exception {
        UUID employeeId = UUID.randomUUID();
        byte[] bytes = {(byte) 0x89, 0x50, 0x4e, 0x47};
        AttachmentAccessPort attachments = mock(AttachmentAccessPort.class);
        when(attachments.openSelectedAvatar("EMPLOYEE", employeeId)).thenReturn(Optional.of(
                new AttachmentAccessPort.AvatarContent(new ByteArrayInputStream(bytes),
                        "image/png", "portrait.png", bytes.length, "source-digest")));
        var response = controller(attachments).avatar(employeeId);
        assertThat(response.getStatusCode().value()).isEqualTo(200);
        assertThat(response.getHeaders().getContentType().toString()).isEqualTo("image/png");
        assertThat(response.getHeaders().getContentLength()).isEqualTo(bytes.length);
        assertThat(response.getHeaders().getFirst(HttpHeaders.CACHE_CONTROL)).isEqualTo("private, no-store");
        assertThat(response.getHeaders().getFirst("X-Content-Type-Options")).isEqualTo("nosniff");
        try (var stream = response.getBody().getInputStream()) {
            assertThat(stream.readAllBytes()).containsExactly(bytes);
        }
        verify(attachments).openSelectedAvatar("EMPLOYEE", employeeId);
        verifyNoMoreInteractions(attachments);
    }

    @Test
    void absentAvatarHasNoFallbackToAnArbitraryEmployeeAttachment() {
        UUID employeeId = UUID.randomUUID();
        AttachmentAccessPort attachments = mock(AttachmentAccessPort.class);
        when(attachments.openSelectedAvatar("EMPLOYEE", employeeId)).thenReturn(Optional.empty());
        assertThat(controller(attachments).avatar(employeeId).getStatusCode().value()).isEqualTo(404);
        verify(attachments).openSelectedAvatar("EMPLOYEE", employeeId);
        verifyNoMoreInteractions(attachments);
    }

    private EmployeeController controller(AttachmentAccessPort attachments) {
        return new EmployeeController(mock(EmployeeQueryService.class),
                mock(EmployeeOnboardingService.class), mock(EmployeeCommandService.class),
                mock(UserAccountAdminService.class), mock(DataHandoverService.class),
                mock(AuditDetailViewRecorder.class), attachments);
    }
}
