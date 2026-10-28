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
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class PiiKeyRotationSecurityContractTest {
    @Test void everyScanStateKeepsKeyRetirementClosedWithoutReadingPrivatePreservationPayloads() throws Exception {
        for(String checkpointStatus:List.of("RUNNING","SCANNED","RESCAN_REQUIRED"))for(boolean oldCipher:new boolean[]{false,true}) {
            UUID actor=UUID.randomUUID(),run=UUID.randomUUID();
            List<String> statements=new ArrayList<>();
            var db=mock(JdbcTemplate.class,call->{
                if(call.getArguments().length>0&&call.getArgument(0) instanceof String sql)statements.add(sql);
                return RETURNS_DEFAULTS.answer(call);
            });
            when(db.queryForObject(anyString(),eq(Boolean.class),eq(actor))).thenReturn(true);
            when(db.queryForObject(contains("LEGACY_UNKNOWN"),eq(Long.class))).thenReturn(0L);
            when(db.query(anyString(),org.mockito.ArgumentMatchers.<org.springframework.jdbc.core.RowMapper<?>>any(),eq(run)))
                    .thenAnswer(call->{
                        var row=mock(java.sql.ResultSet.class);
                        when(row.getString(1)).thenReturn("2");when(row.getString(2)).thenReturn(PiiRotationCatalog.VERSION);
                        when(row.getInt(3)).thenReturn(PiiRotationCatalog.TARGETS.size());when(row.getString(4)).thenReturn("");
                        when(row.getLong(5)).thenReturn(1L);when(row.getLong(6)).thenReturn(27L);when(row.getLong(7)).thenReturn(27L);
                        when(row.getString(8)).thenReturn(checkpointStatus);
                        org.springframework.jdbc.core.RowMapper<?> mapper=call.getArgument(1);
                        return List.of(mapper.mapRow(row,0));
                    });
            doAnswer(call->{
                if(oldCipher) {
                    var row=mock(java.sql.ResultSet.class);when(row.getString(1)).thenReturn("1");when(row.getLong(2)).thenReturn(1L);
                    org.springframework.jdbc.core.RowCallbackHandler consumer=call.getArgument(1);consumer.processRow(row);
                }
                return null;
            }).when(db).query(startsWith("WITH values_to_check AS"),any(org.springframework.jdbc.core.RowCallbackHandler.class),eq("2"));
            var user=mock(SecurityContextCurrentUser.class);
            when(user.get()).thenReturn(Optional.of(new AuthUser(actor,UUID.randomUUID(),"rotation-test",
                    Set.of("pii_key_rotation:manage"),false,true,true)));
            var cipher=mock(PiiCipherRewrapper.class);
            var service=new PiiKeyRotationService(db,cipher,user,mock(TxSessionVars.class),mock(AuditService.class),true,"local");
            var progress=service.status(run);
            assertEquals("SCANNED".equals(checkpointStatus)&&oldCipher?"RESCAN_REQUIRED":checkpointStatus,progress.status());
            assertEquals(oldCipher?Map.of("1",1L):Map.of(),progress.remainingByVersion());
            assertFalse(progress.canRemoveOldKeys(),"even an empty completed app inventory does not authorize removal of preservation/backup keys");
            assertTrue(statements.stream().noneMatch(sql->sql.contains("employee_identity_merge_payloads")||sql.contains("snapshot_enc")));
            verifyNoInteractions(cipher);
            when(db.queryForObject(anyString(),eq(Boolean.class))).thenReturn(true);
            when(cipher.currentVersion()).thenReturn("2");
            var replay=service.batch(run,"2",0,1);
            assertEquals(progress.status(),replay.status());
            assertFalse(replay.canRemoveOldKeys(),"a submitted batch replay cannot authorize key retirement either");
            verify(cipher,never()).rewrap(any(),any());
            assertTrue(statements.stream().noneMatch(sql->sql.contains("employee_identity_merge_payloads")||sql.contains("snapshot_enc")));
        }
    }

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
