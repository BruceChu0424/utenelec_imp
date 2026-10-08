package com.uten.imp.security;

import com.uten.imp.features.admin.crypto.PiiKeyRotationController;
import org.junit.jupiter.api.Test;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Profile;
import org.springframework.security.access.prepost.PreAuthorize;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.audit.AuditService;
import org.springframework.jdbc.core.JdbcTemplate;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class PiiKeyRotationSecurityContractTest {
    @Test void disabledAndCloudInstancesRejectBeforeReadingKeysOrWritingCheckpoints() {
        for(String site:new String[]{"local","cloud"}) {
            var db=mock(JdbcTemplate.class);var cipher=mock(PiiCipherRewrapper.class);var user=mock(SecurityContextCurrentUser.class);
            var service=new PiiKeyRotationService(db,cipher,user,mock(TxSessionVars.class),mock(AuditService.class),"cloud".equals(site),site);
            assertThrows(ApiException.class,()->service.batch(UUID.randomUUID(),"2",0,10));
            verifyNoInteractions(db,cipher,user);
        }
    }

    @Test void impersonationCannotTurnASuperAdminSessionIntoMaintenanceAuthority() {
        var db=mock(JdbcTemplate.class);var cipher=mock(PiiCipherRewrapper.class);var user=mock(SecurityContextCurrentUser.class);
        when(user.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"test-admin",
                Set.of("pii_key_rotation:manage"),false,true,true,false,UUID.randomUUID())));
        var service=new PiiKeyRotationService(db,cipher,user,mock(TxSessionVars.class),mock(AuditService.class),true,"local");
        assertThrows(ApiException.class,()->service.batch(UUID.randomUUID(),"2",0,10));
        verifyNoInteractions(db,cipher);
    }

    @Test void maintenanceIsOptInLocalAndRequiresDedicatedSuperAdminPermissionAndStepUp() throws Exception {
        var controller = PiiKeyRotationController.class;
        assertArrayEquals(new String[]{"!cloud"},controller.getAnnotation(Profile.class).value());
        var feature = controller.getAnnotation(ConditionalOnProperty.class);
        assertEquals("uten.crypto.rotation",feature.prefix()); assertEquals("true",feature.havingValue());
        assertFalse(feature.matchIfMissing());
        assertEquals("principal.superAdmin and hasAuthority('pii_key_rotation:manage')",
                controller.getAnnotation(PreAuthorize.class).value());
        assertNotNull(controller.getMethod("batch",PiiKeyRotationController.BatchRequest.class).getAnnotation(RequiresStepUp.class));
        assertEquals(controller.getAnnotation(PreAuthorize.class).value(),PiiKeyRotationService.class.getAnnotation(PreAuthorize.class).value());
    }
}
