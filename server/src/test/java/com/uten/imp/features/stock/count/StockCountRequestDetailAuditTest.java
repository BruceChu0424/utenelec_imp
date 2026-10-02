package com.uten.imp.features.stock.count;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;
import java.util.Map;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;

class StockCountRequestDetailAuditTest {
    private final StockCountRequestService service=mock(StockCountRequestService.class);
    private final AuditDetailViewRecorder recorder=mock(AuditDetailViewRecorder.class);
    private StockCountRequestController controller() {return new StockCountRequestController(service,recorder,mock(WarehouseTaskScopePort.class));}
    @Test void successfulAuthorizedDetailRecordsOnlyTheSafeRequestIdentityOnce() throws Exception {
        UUID id=UUID.randomUUID();var detail=Map.<String,Object>of("requestNo","PD-001","reason","PRIVATE REASON","targetQty","999");
        when(service.detail(id)).thenReturn(detail);
        assertThat(controller().detail(id)).isSameAs(detail);
        verify(recorder).record("view_stock_count_request_detail","stock_count_requests",id,"PD-001",null,"库存盘点申请");
        verifyNoMoreInteractions(recorder);
    }
    @Test void deniedOrMissingDetailCannotPublishASuccessfulViewEvent() throws Exception {
        UUID id=UUID.randomUUID();when(service.detail(id)).thenThrow(new ApiException(ErrorCode.FORBIDDEN));
        assertThatThrownBy(()->controller().detail(id)).isInstanceOf(ApiException.class);
        doThrow(new ApiException(ErrorCode.NOT_FOUND)).when(service).detail(id);
        assertThatThrownBy(()->controller().detail(id)).isInstanceOf(ApiException.class);
        verifyNoInteractions(recorder);
    }
}
