package com.uten.imp.features.notice;

import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.notice.outbox.BusinessOutboxPublisher;
import com.uten.imp.features.rbac.UserRoleRepository;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.Map;
import java.util.UUID;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

class ChainNoticeReadyEventTest {

    @Test
    void publishesOneReceiptScopedReadyEvent() {
        BusinessOutboxPublisher outbox =
                mock(BusinessOutboxPublisher.class);
        ChainNoticeService service = new ChainNoticeService(
                mock(NoticeService.class),
                mock(UserAccountRepository.class),
                mock(com.uten.imp.features.auth.PermissionResolver.class),
                mock(UserRoleRepository.class),
                mock(JdbcTemplate.class),
                outbox,
                mock(com.uten.imp.features.rd_task.RdTaskService.class),
                mock(FinanceReviewerEligibilityPort.class),
                mock(com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility.class));
        UUID segmentId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();

        service.notifyExecutionSegmentReady(
                segmentId, receiptId, "PURCHASE");

        verify(outbox).publishOnce(
                ChainNoticeService.EVENT_SEGMENT_READY,
                "PRODUCTION_EXECUTION_SEGMENT",
                segmentId,
                Map.of(
                        "triggeringReceiptId", receiptId.toString(),
                        "sourceType", "PURCHASE"),
                ChainNoticeService.EVENT_SEGMENT_READY + ':'
                        + segmentId + ':' + receiptId);
    }
}
