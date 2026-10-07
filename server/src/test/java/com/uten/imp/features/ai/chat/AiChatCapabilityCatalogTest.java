package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.application.port.AiCompletionPort;
import com.uten.imp.features.ai.job.AiJobService;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class AiChatCapabilityCatalogTest {
    @Test void catalogComesFromRegisteredPortsAndIsRebuiltOnPermissionChanges() {
        var access=mock(AiChatAccessPolicy.class);
        var actor=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"staff",Set.of("ai:use"),false,true,false);
        when(access.requireChat()).thenReturn(actor);
        when(access.domains()).thenReturn(Set.of("SELF","WAREHOUSE"));
        var tool=mock(AiChatToolPort.class);
        when(tool.name()).thenReturn("registered_inventory"); when(tool.title()).thenReturn("新登记库存查询");
        when(tool.description()).thenReturn("库存只读"); when(tool.domain()).thenReturn("WAREHOUSE"); when(tool.available()).thenReturn(true);
        var registry=new AiChatToolRegistry(List.of(tool),access);
        var ai=mock(AiCompletionPort.class);
        when(ai.availability()).thenReturn(new AiCompletionPort.AiAvailability(false,null,null,false,null));
        var workflows=mock(AiDocumentWorkflows.class); when(workflows.available()).thenReturn(List.of());
        var jobs=mock(AiJobService.class);
        var settings=mock(AiChatSettingsService.class); when(settings.current()).thenReturn(AiChatSettings.DEFAULTS);
        var controller=new AiChatController(jobs,access,mock(AiChatEvidence.class),ai,
                mock(AiChatPageGuideCatalog.class),new ObjectMapper(),registry,workflows,settings,mock(AiChatJobHandler.class),
                mock(AiChatOperationMemoryService.class));
        var first=controller.capabilities();
        assertThat(first.get("settings")).isEqualTo(AiChatSettings.DEFAULTS.toJson());
        assertThat(first.get("canUploadDocument")).as("recognizing a file needs only chat access").isEqualTo(true);
        assertThat(first.get("reasoningEffortSupported")).isEqualTo(false);
        assertThat(first.get("tools").toString()).contains("registered_inventory");
        assertThat(first.get("catalogVersion").toString()).matches("[a-f0-9]{64}");
        assertThat(controller.capabilities().get("catalogVersion")).isEqualTo(first.get("catalogVersion"));
        when(access.domains()).thenReturn(Set.of("SELF"));
        var revoked=controller.capabilities();
        assertThat(revoked.get("tools")).isEqualTo(List.of());
        assertThat(revoked.get("catalogVersion")).isNotEqualTo(first.get("catalogVersion"));
        verifyNoInteractions(jobs);
    }
}
