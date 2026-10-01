package com.uten.imp.common.history;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.sales.shipment.dto.ShipmentDetail;
import com.uten.imp.features.purchase.receipt.dto.ReceiptDetail;
import java.util.Arrays;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;
import static org.assertj.core.api.Assertions.*;

class DocumentHistorySerializationTest {
    @org.junit.jupiter.params.ParameterizedTest
    @org.junit.jupiter.params.provider.ValueSource(strings={
            "com.uten.imp.features.purchase.order.dto.OrderDetail",
            "com.uten.imp.features.purchase.order.dto.OrderListItem",
            "com.uten.imp.features.subcontract.order.dto.OrderDetail",
            "com.uten.imp.features.subcontract.order.dto.OrderListItem"})
    void historicalProcurementKeepsFinanceFactsButNoNestedActions(String name)throws Exception {
        var view=(DocumentHistoryMetadata)empty(Class.forName(name));
        var finance=new com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval(
                null,"NONE",0,0,null,null,"审批人",null,null,java.util.List.of("SUBMIT"));
        ReflectionTestUtils.setField(view,"financeApproval",finance);
        view.setHistoryReadOnly(true);
        var json=new ObjectMapper().findAndRegisterModules().valueToTree(view);
        assertThat(json.path("financeApproval").path("allowedActions")).isEmpty();
        assertThat(json.path("financeApproval").path("assigneeName").asText()).isEqualTo("审批人");
        assertThat(json.path("financeApproval").path("status").asText()).isEqualTo("NONE");
    }
    @Test void flattenedShipmentWorkflowCannotAdvertiseActionsOnHistoricalDraft() throws Exception {
        ShipmentDetail view=empty(ShipmentDetail.class);
        ReflectionTestUtils.setField(view,"status",(short)0);
        view.getWorkflow().setCanConfirmSales(true);
        view.getWorkflow().setCanResubmitAfterFinanceReject(true);
        var history=new DocumentHistoryMetadata();history.setDeleted(true);history.setHistoryReadOnly(true);
        view.copyHistoryFrom(history);
        var json=new ObjectMapper().findAndRegisterModules().valueToTree(view);
        assertThat(json.path("status").asInt()).isZero();
        assertThat(json.path("deleted").asBoolean()).isTrue();
        assertThat(json.path("historyReadOnly").asBoolean()).isTrue();
        for(String action:new String[]{"writable","canReject","canManageWarehouseWork","canConfirmSales","canResubmitAfterFinanceReject"}) {
            assertThat(json.has(action)).as(action).isTrue();
            assertThat(json.path(action).asBoolean()).as(action).isFalse();
        }
    }
    @Test void interfaceCapabilitiesRespectNativeHistoryWithoutChangingStatus() throws Exception {
        ReceiptDetail view=empty(ReceiptDetail.class);ReflectionTestUtils.setField(view,"status",(short)0);
        assertThat(view.isCanApprove()).isTrue();
        var history=new DocumentHistoryMetadata();history.setHistoryReadOnly(true);view.copyHistoryFrom(history);
        var json=new ObjectMapper().findAndRegisterModules().valueToTree(view);
        for(String action:new String[]{"canEdit","canDelete","canReverse","canApprove"}) assertThat(json.path(action).asBoolean()).as(action).isFalse();
        assertThat(json.path("status").asInt()).isZero();
    }
    private static <T> T empty(Class<T> type)throws Exception {
        var constructor=Arrays.stream(type.getConstructors()).max(java.util.Comparator.comparingInt(java.lang.reflect.Constructor::getParameterCount)).orElseThrow();
        Object[] arguments=Arrays.stream(constructor.getParameterTypes()).map(parameter -> {
            if(parameter==boolean.class)return Boolean.TRUE;
            if(parameter==int.class)return Integer.valueOf(0);
            if(parameter==long.class)return Long.valueOf(0L);
            return (Object)null;
        }).toArray();
        return type.cast(constructor.newInstance(arguments));
    }
}
