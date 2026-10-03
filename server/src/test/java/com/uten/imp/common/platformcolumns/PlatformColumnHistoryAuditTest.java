package com.uten.imp.common.platformcolumns;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditEventInterpreter;
import com.uten.imp.audit.AuditLog;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class PlatformColumnHistoryAuditTest {
    @Test void successfulAuthorizedHistoryRecordsOneExplicitNativeView() {
        var service=mock(PlatformColumnService.class);var views=mock(AuditDetailViewRecorder.class);var id=UUID.randomUUID();
        when(service.history("sales_order",id,null,20)).thenReturn(List.of());
        new PlatformColumnController(service,views).history("sales_order",id,null,20);
        verify(views).record("view_platform_field_history_detail","platform_record_fields",id,null,null,"业务扩展字段历史");
        verifyNoMoreInteractions(views);
    }
    @Test void deniedHistoryCannotCreateASuccessfulViewRecord() {
        var service=mock(PlatformColumnService.class);var views=mock(AuditDetailViewRecorder.class);var id=UUID.randomUUID();
        when(service.history("sales_order",id,null,20)).thenThrow(new ApiException(ErrorCode.FORBIDDEN));
        assertThatThrownBy(()->new PlatformColumnController(service,views).history("sales_order",id,null,20)).isInstanceOf(ApiException.class);
        verifyNoInteractions(views);
    }
    @Test void interpreterKeepsTheBusinessFieldHistoryLabel() {
        var log=new AuditLog();log.setAction("view_platform_field_history_detail");log.setTargetType("platform_record_fields");
        log.setTargetId(UUID.randomUUID().toString());log.setHttpMethod("GET");log.setResult("success");
        var event=new AuditEventInterpreter().interpret(log);
        assertThat(event.actionLabel()).isEqualTo("查看业务扩展字段历史");assertThat(event.objectLabel()).isEqualTo("业务扩展字段");
    }
}
