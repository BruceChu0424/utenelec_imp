package com.uten.imp.features.attachment;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditEventInterpreter;
import com.uten.imp.audit.AuditLog;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.attachment.dto.AttachmentDto;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class AttachmentHistoryAuditTest {
    AttachmentService service=mock(AttachmentService.class);
    AuditDetailViewRecorder detailViews=mock(AuditDetailViewRecorder.class);
    AttachmentController controller=new AttachmentController(service,mock(AttachmentReconciliationService.class),
            mock(AttachmentPreviewService.class),detailViews);

    @Test void authorizedResolvedHistoryProducesOneStableDetailView() {
        UUID id=UUID.randomUUID();AttachmentDto dto=mock(AttachmentDto.class);
        when(service.history(id)).thenReturn(dto);
        assertThat(controller.history(id)).isSameAs(dto);
        var order=inOrder(service,detailViews);order.verify(service).history(id);
        order.verify(detailViews).record("view_attachment_history_detail","attachments",id,null,null,"附件历史");
        verifyNoMoreInteractions(detailViews);
    }
    @Test void forbiddenAndMissingHistoryNeverProduceASuccessView() {
        for(ErrorCode code:new ErrorCode[]{ErrorCode.FORBIDDEN,ErrorCode.NOT_FOUND}) {
            UUID id=UUID.randomUUID();when(service.history(id)).thenThrow(new ApiException(code));
            assertThatThrownBy(()->controller.history(id)).isInstanceOf(ApiException.class);
        }
        verifyNoInteractions(detailViews);
    }
    @Test void retainedHistoryActionsHaveChineseBusinessLabelsWithoutInventedDeletion() {
        Map<String,String> labels=Map.of("view_attachment_history_detail","查看附件历史",
                "attachment_history_download","下载已保留附件原件",
                "attachment_logical_delete","标记附件已删除并保留历史");
        var interpreter=new AuditEventInterpreter();
        labels.forEach((action,expected)->{
            var log=new AuditLog();log.setAction(action);log.setTargetType("attachments");log.setEventSource("business");log.setResult("success");
            assertThat(interpreter.interpret(log).actionLabel()).isEqualTo(expected);
            assertThat(interpreter.interpret(log).objectLabel()).isEqualTo("附件");
        });
    }
}
