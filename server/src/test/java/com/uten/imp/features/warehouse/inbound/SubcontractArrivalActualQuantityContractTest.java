package com.uten.imp.features.warehouse.inbound;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class SubcontractArrivalActualQuantityContractTest {
    @Test
    void targetObligationPhysicalCapacityAndNormalAllowanceKeepTheirOwnExactValues() throws Exception {
        var mapper=new ObjectMapper().findAndRegisterModules();
        var item=mapper.readValue("""
                {"orderedQty":"1000.0000","acceptedQty":"0.0000",
                 "remainingQty":"1100.0000","registeredQty":"50.0000",
                 "pendingReturnQty":"1000.0000","materialReceivableQty":"1050.0000",
                 "normalMaxReceivableQty":"1050.0000"}
                """,ProcurementArrivalContracts.InboundExpectationItem.class);
        var json=mapper.valueToTree(item);
        assertThat(item.pendingReturnQty()).isEqualByComparingTo("1000");
        assertThat(item.materialReceivableQty()).isEqualByComparingTo("1050");
        assertThat(item.normalMaxReceivableQty()).isEqualByComparingTo("1050");
        assertThat(json.path("orderedQtyExact").asText()).isEqualTo("1000.0000");
        assertThat(json.path("pendingReturnQtyExact").asText()).isEqualTo("1000.0000");
        assertThat(json.path("materialReceivableQtyExact").asText()).isEqualTo("1050.0000");
        assertThat(json.path("normalMaxReceivableQtyExact").asText()).isEqualTo("1050.0000");
        assertThat(item.expectedAllocations()).isEmpty();
    }

    @Test
    void oldOrPurchaseContractsKeepNewSubcontractAuthorityAbsent() throws Exception {
        var mapper=new ObjectMapper().findAndRegisterModules();
        var item=mapper.readValue("""
                {"orderedQty":"1000","acceptedQty":"200","remainingQty":"800","registeredQty":"50"}
                """,ProcurementArrivalContracts.InboundExpectationItem.class);
        assertThat(item.pendingReturnQty()).isNull();
        assertThat(item.materialReceivableQty()).isNull();
        assertThat(item.normalMaxReceivableQty()).isNull();
        assertThat(item.remainingQty()).isEqualByComparingTo("800");
        assertThat(item.registeredQty()).isEqualByComparingTo("50");
    }
}
