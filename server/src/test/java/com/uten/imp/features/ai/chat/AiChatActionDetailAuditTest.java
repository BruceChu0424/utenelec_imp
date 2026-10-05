package com.uten.imp.features.ai.chat;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.verifyNoMoreInteractions;
import static org.mockito.Mockito.when;

/** ADR-150 confirmation-card re-read follows the platform detail-view audit rule. */
class AiChatActionDetailAuditTest {
    private final AiChatActionProposalService proposals = mock(AiChatActionProposalService.class);
    private final AuditDetailViewRecorder recorder = mock(AuditDetailViewRecorder.class);
    private final AiChatActionController controller = new AiChatActionController(proposals, recorder);

    @Test
    void ownersSuccessfulCardReadRecordsOneDetailViewWithoutCardContent() {
        UUID id = UUID.randomUUID();
        Map<String, Object> card = Map.of("proposalId", id.toString(), "title", "PRIVATE TITLE");
        when(proposals.view(id)).thenReturn(card);

        assertThat(controller.view(id)).isSameAs(card);

        verify(recorder).record("view_ai_chat_action_proposal_detail", "ai_chat_action_proposals", id,
                null, null, "AI 操作确认卡");
        verifyNoMoreInteractions(recorder);
    }

    @Test
    void foreignOrMissingCardRecordsNoSuccessfulView() {
        UUID id = UUID.randomUUID();
        when(proposals.view(id)).thenThrow(new ApiException(ErrorCode.NOT_FOUND));

        assertThatThrownBy(() -> controller.view(id)).isInstanceOf(ApiException.class);

        verifyNoInteractions(recorder);
    }
}
