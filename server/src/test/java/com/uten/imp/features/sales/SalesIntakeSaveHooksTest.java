package com.uten.imp.features.sales;

import com.uten.imp.application.port.SalesMasterLearningPort;
import com.uten.imp.application.port.SalesMasterLearningPort.LearnedLine;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.intake.SalesIntakeUsedEvent;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.context.ApplicationEventPublisher;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/** ADR-134 保存后学习挂钩: 只交带文件原文的行, 用了识别任务才发布采用事件, 什么都没有时不打扰学习出口。 */
class SalesIntakeSaveHooksTest {

    private final SalesMasterLearningPort learning = mock(SalesMasterLearningPort.class);
    private final ApplicationEventPublisher events = mock(ApplicationEventPublisher.class);
    private final SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
    private final UUID userId = UUID.randomUUID();
    private final UUID employeeId = UUID.randomUUID();

    @SuppressWarnings("unchecked")
    private SalesIntakeSaveHooks hooks(SalesMasterLearningPort port) {
        ObjectProvider<SalesMasterLearningPort> provider = mock(ObjectProvider.class);
        when(provider.getIfAvailable()).thenReturn(port);
        when(currentUser.requireId()).thenReturn(userId);
        when(currentUser.employeeId()).thenReturn(Optional.of(employeeId));
        return new SalesIntakeSaveHooks(provider, events, currentUser);
    }

    @Test
    void onlyLinesWithCustomerTextAreLearnedAndTheJobUseIsAnnounced() {
        UUID docId = UUID.randomUUID();
        UUID clientId = UUID.randomUUID();
        UUID jobId = UUID.randomUUID();
        UUID goodsA = UUID.randomUUID();
        UUID goodsB = UUID.randomUUID();
        SalesAiIntakeRequest intake = new SalesAiIntakeRequest();
        intake.setJobId(jobId);
        Map<String, String> fields = new LinkedHashMap<>();
        fields.put(" email ", " buyer@example.test ");
        fields.put("address", "  ");
        intake.setClientFields(fields);

        hooks(learning).afterSave(SalesIntakeSaveHooks.DOC_QUOTE, docId, clientId, List.of(
                new LearnedLine(goodsA, "GZ23/D", "DOUBLE SOCKET", "S1R9", true, true),
                new LearnedLine(goodsB, null, " ", null, false, false)), intake);

        ArgumentCaptor<SalesMasterLearningPort.SalesLearningRequest> request =
                ArgumentCaptor.forClass(SalesMasterLearningPort.SalesLearningRequest.class);
        verify(learning).learnAfterCommit(request.capture());
        assertThat(request.getValue().docType()).isEqualTo("quote");
        assertThat(request.getValue().docId()).isEqualTo(docId);
        assertThat(request.getValue().clientId()).isEqualTo(clientId);
        assertThat(request.getValue().actorUserId()).isEqualTo(userId);
        assertThat(request.getValue().actorEmployeeId()).isEqualTo(employeeId);
        assertThat(request.getValue().intakeJobId()).isEqualTo(jobId);
        assertThat(request.getValue().lines()).extracting(LearnedLine::goodsId).containsExactly(goodsA);
        assertThat(request.getValue().lines().getFirst().setNameEn()).isTrue();
        assertThat(request.getValue().clientFields()).containsExactly(Map.entry("email", "buyer@example.test"));

        ArgumentCaptor<Object> event = ArgumentCaptor.forClass(Object.class);
        verify(events).publishEvent(event.capture());
        assertThat(event.getValue()).isEqualTo(
                new SalesIntakeUsedEvent(jobId, userId, "quote", docId, clientId, List.of("S1R9"), request.getValue().learningReceiptId()));
    }

    @Test
    void batchOnlyAnnouncesAdditionalJobsThatContributedSavedRows() {
        UUID first = UUID.randomUUID(), last = UUID.randomUUID(), unused = UUID.randomUUID();
        UUID doc = UUID.randomUUID(), client = UUID.randomUUID();
        SalesAiIntakeRequest intake = new SalesAiIntakeRequest();
        intake.setJobId(last);
        intake.setAdditionalJobIds(List.of(first, first, unused));
        hooks(learning).afterSave("quote", doc, client,
                List.of(new LearnedLine(UUID.randomUUID(), "A", null, first + ":S1R9", true, false)), intake);
        var capture = ArgumentCaptor.forClass(SalesMasterLearningPort.SalesLearningRequest.class);
        verify(learning).learnAfterCommit(capture.capture());
        assertThat(capture.getValue().intakeJobIds()).containsExactly(last, first);
        verify(events).publishEvent(new SalesIntakeUsedEvent(first, userId, "quote", doc, client, List.of("S1R9"), capture.getValue().learningReceiptId()));
        verify(events, never()).publishEvent(org.mockito.ArgumentMatchers.argThat((Object value) ->
                value instanceof SalesIntakeUsedEvent event && event.jobId().equals(unused)));
    }

    @Test
    void handTypedCustomerTextIsLearnedWithoutAnIntakeEvent() {
        UUID goods = UUID.randomUUID();
        hooks(learning).afterSave(SalesIntakeSaveHooks.DOC_ORDER, UUID.randomUUID(), UUID.randomUUID(),
                List.of(new LearnedLine(goods, "K20AD-01", null, null, true, false)), null);
        verify(learning).learnAfterCommit(any());
        verify(events, never()).publishEvent(any(Object.class));
    }

    @Test
    void savesWithoutCustomerTextOrJobLeaveLearningAlone() {
        hooks(learning).afterSave(SalesIntakeSaveHooks.DOC_ORDER, UUID.randomUUID(), UUID.randomUUID(),
                List.of(new LearnedLine(UUID.randomUUID(), null, null, null, false, false)),
                new SalesAiIntakeRequest());
        verify(learning, never()).learnAfterCommit(any());
        verifyNoInteractions(events);
    }

    @Test
    void clearingAllLearnedLabelsStillEnqueuesOneDocumentRetraction() {
        UUID doc=UUID.randomUUID();
        when(learning.hasDocumentLearning("order",doc)).thenReturn(true);
        hooks(learning).afterSave("order",doc,UUID.randomUUID(),List.of(),null);
        var capture=ArgumentCaptor.forClass(SalesMasterLearningPort.SalesLearningRequest.class);
        verify(learning).learnAfterCommit(capture.capture());
        assertThat(capture.getValue().lines()).isEmpty();
        assertThat(capture.getValue().learningReceiptId()).isNotNull();
        verifyNoInteractions(events);
    }

    @Test
    void tickedClientFieldsFailClosedWhenTheLearningAdapterIsMissing() {
        SalesAiIntakeRequest intake = new SalesAiIntakeRequest();
        intake.setJobId(UUID.randomUUID());
        intake.setClientFields(Map.of("email", "buyer@example.test"));
        assertThatThrownBy(() -> hooks(null).afterSave(SalesIntakeSaveHooks.DOC_QUOTE,
                UUID.randomUUID(), UUID.randomUUID(), List.of(), intake))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("客户资料")
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.CONFLICT);
        verifyNoInteractions(events);
    }
}
