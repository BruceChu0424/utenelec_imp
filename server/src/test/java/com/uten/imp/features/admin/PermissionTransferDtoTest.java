package com.uten.imp.features.admin;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.admin.dto.PermissionTransferDtos.*;
import org.junit.jupiter.api.Test;
import java.util.List;
import static org.assertj.core.api.Assertions.*;

class PermissionTransferDtoTest {
    private final ObjectMapper mapper = new ObjectMapper().disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES);
    @Test void unknownIdentityAndCredentialFieldsAreRejectedEvenWhenGlobalMapperIgnoresUnknownProperties() {
        for (String field : List.of("passwordHash","remoteAccess","superAdmin")) {
            assertThatThrownBy(() -> mapper.readValue("{\"format\":\"uten.permission-configuration\",\"version\":1,\""+field+"\":true}",Backup.class))
                    .hasMessageContaining("不支持的字段");
        }
        assertThatThrownBy(() -> mapper.readValue("{\"key\":\"source\",\"superAdmin\":true}",UserConfiguration.class))
                .hasMessageContaining("不支持的字段");
    }
    @Test void portableBackupRoundTripsWithoutCredentialOrIdentityFlags() throws Exception {
        Backup backup=new Backup("uten.permission-configuration",1,"2026-10-17T00:00:00Z",List.of("notice:read"),List.of(),List.of(),List.of());
        String json=mapper.writeValueAsString(backup);
        assertThat(mapper.readValue(json,Backup.class)).isEqualTo(backup);
        assertThat(json).doesNotContain("password","superAdmin","remoteAccess");
    }
    @Test void transferReceiptsAreRetainedAuthorizationEvidence() {
        for(String action:List.of("permission_configuration_import","permission_configuration_copy")) {
            var classification=com.uten.imp.audit.AuditClassifier.classify("business",action,"permissions","", "success",200);
            assertThat(classification.eventCategory()).isEqualTo("authorization");
            assertThat(classification.riskLevel()).isEqualTo("high");
        }
    }
    @Test void everyCommitHasStepUpAndEveryEndpointHasTheSuperAdministratorBoundary() throws Exception {
        var controller=PermissionConfigurationTransferController.class;
        assertThat(controller.getAnnotation(org.springframework.security.access.prepost.PreAuthorize.class).value())
                .contains("authorization:manage","principal.superAdmin");
        assertThat(controller.getMethod("importConfiguration",ImportCommit.class).getAnnotation(com.uten.imp.security.RequiresStepUp.class)).isNotNull();
        assertThat(controller.getMethod("copyPermissions",java.util.UUID.class,CopyCommit.class).getAnnotation(com.uten.imp.security.RequiresStepUp.class)).isNotNull();
        for(var method:List.of(controller.getMethod("previewImport",ImportRequest.class),controller.getMethod("previewCopy",java.util.UUID.class,CopyRequest.class))) {
            assertThat(method.getAnnotation(com.uten.imp.security.StepUpExempt.class)).isNotNull();
            assertThat(method.getAnnotation(com.uten.imp.security.RequiresStepUp.class)).isNull();
        }
        for(var method:List.of(PermissionConfigurationTransferService.class.getMethod("previewImport",ImportRequest.class),
                PermissionConfigurationTransferService.class.getMethod("previewCopy",java.util.UUID.class,CopyRequest.class))) {
            assertThat(method.getAnnotation(org.springframework.transaction.annotation.Transactional.class).readOnly()).isTrue();
        }
    }
}
