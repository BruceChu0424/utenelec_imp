package com.uten.imp.features.ai.chat;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.ai.job.AiJobService;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SubmitterPrincipalRestorer;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class AiChatEvidenceTest {
    private final AiJobService jobs = mock(AiJobService.class);
    private final AiChatAccessPolicy access = mock(AiChatAccessPolicy.class);
    private final SubmitterPrincipalRestorer principals = mock(SubmitterPrincipalRestorer.class);
    private final AiChatEvidence evidence = new AiChatEvidence(jobs, access, principals);
    private final AuthUser actor = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "actor", Set.of("ai:use", "sales_order:view", "sales_order:create"), false, true, false);
    @BeforeEach void before() {
        when(access.requireChat()).thenReturn(actor);
        when(access.membershipFingerprint()).thenReturn("a:DEPT_SALES");
        when(principals.currentStamps(actor.getId())).thenReturn(Optional.of(new SubmitterPrincipalRestorer.AuthorizationStamps(4, 9)));
    }
    @Test void revokedAuthorizationBlocksOldAnswers() {
        Map<String, Object> stamp = evidence.stamp();
        when(principals.currentStamps(actor.getId())).thenReturn(Optional.of(new SubmitterPrincipalRestorer.AuthorizationStamps(4, 10)));
        assertThatThrownBy(() -> evidence.requireStamp(stamp)).isInstanceOf(ApiException.class);
    }
    @Test void samePermissionsAfterDepartmentMoveStillBlockHistory() {
        Map<String, Object> stamp = evidence.stamp();
        when(access.membershipFingerprint()).thenReturn("b:DEPT_SALES");
        assertThatThrownBy(() -> evidence.requireStamp(stamp)).isInstanceOf(ApiException.class);
    }
    @Test void conversationHistoryIsReadOnlyThroughTheOwnersChatJobs() {
        UUID conversation = UUID.randomUUID();
        when(jobs.conversationResults(AiChatJobHandler.KIND, actor, conversation, 6)).thenReturn(List.of());
        assertThat(evidence.conversation(conversation, 6)).isEmpty();
        verify(jobs).conversationResults(AiChatJobHandler.KIND, actor, conversation, 6);
    }
    @Test void changedIdentityIsReportedWithoutThrowing() {
        Map<String, Object> stamp = evidence.stamp();
        assertThat(evidence.stampMatches(stamp)).isTrue();
        when(access.membershipFingerprint()).thenReturn("b:DEPT_SALES");
        assertThat(evidence.stampMatches(stamp)).isFalse();
        assertThat(evidence.stampMatches(null)).isFalse();
    }
}
