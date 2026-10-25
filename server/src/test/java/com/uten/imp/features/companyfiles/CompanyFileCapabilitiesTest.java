package com.uten.imp.features.companyfiles;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

import com.uten.imp.application.port.AttachmentAccessPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;

import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

class CompanyFileCapabilitiesTest {
    @Test
    void unboundBootstrapAccountCanManageMetadataButNeverAdvertisesOrStartsAnAttachmentUpload() {
        var current = mock(SecurityContextCurrentUser.class);
        var actor =
                new AuthUser(
                        UUID.randomUUID(),
                        null,
                        "bootstrap",
                        Set.of(
                                "company_file:view",
                                "company_file:create",
                                "company_file:upload",
                                "company_file:download",
                                "company_file:move",
                                "attachment:view",
                                "attachment:upload",
                                "attachment:download"),
                        false,
                        true,
                        true,
                        false,
                        null,
                        UUID.randomUUID());
        when(current.get()).thenReturn(Optional.of(actor));
        var service =
                new CompanyFileService(
                        mock(JdbcTemplate.class),
                        current,
                        mock(AttachmentAccessPort.class),
                        mock(AuditService.class),
                        new CompanyFileUnlocks());
        var listing = service.list(null, "", "manual", "asc", false, 0, 100);
        assertThat(listing.allowedActions()).containsExactly("view", "create", "move");
        assertThatThrownBy(
                        () ->
                                service.reserveFile(
                                        new CompanyFileDtos.Create(
                                                null,
                                                "cannot-upload.txt",
                                                null,
                                                UUID.randomUUID())))
                .isInstanceOfSatisfying(
                        ApiException.class,
                        e -> assertThat(e.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
    }
}
