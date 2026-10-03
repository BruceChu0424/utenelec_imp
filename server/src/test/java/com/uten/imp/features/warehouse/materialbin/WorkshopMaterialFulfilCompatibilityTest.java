package com.uten.imp.features.warehouse.materialbin;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.FulfilLine;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.FulfilRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MaterialSetup;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.RequisitionView;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Persisted command JSON is part of the retry contract, including old receipts without issueMethod. */
class WorkshopMaterialFulfilCompatibilityTest {
    private static final UUID REQUEST = UUID.fromString("00000000-0000-4000-8000-000000000001");
    private static final UUID LINE = UUID.fromString("00000000-0000-4000-8000-000000000002");
    private static final UUID LEAF = UUID.fromString("00000000-0000-4000-8000-000000000003");
    private static final String KEY = "legacy-fulfil-key";
    private static final String OLD_COMMAND = "[\"00000000-0000-4000-8000-000000000001\","
            + "{\"expectedVersion\":2,\"lines\":[{\"lineId\":\"00000000-0000-4000-8000-000000000002\","
            + "\"leafWarehouseId\":\"00000000-0000-4000-8000-000000000003\",\"qty\":12.50}],"
            + "\"supplement\":null,\"idempotencyKey\":\"legacy-fulfil-key\"}]";

    @Test
    void omittedAndEmptySetupKeepTheStoredLegacyCommandBytes() throws Exception {
        assertEquals(OLD_COMMAND, captured(null));
        assertEquals(OLD_COMMAND, captured(List.of()));
    }

    @Test
    void FirstUseConfirmationIsPartOfTheIdempotentPayload() throws Exception {
        String configured = captured(List.of(new MaterialSetup(LINE, 3L, "OWN")));
        assertNotEquals(OLD_COMMAND, configured);
        assertTrue(configured.contains("\"materialSetup\":[{"));
        assertTrue(configured.contains("\"periodicCostBasis\":\"OWN\""));
    }

    @Test
    void oldReceiptWithoutMaterialIssueMethodStillDeserializes() throws Exception {
        String receipt = """
                {"id":"00000000-0000-4000-8000-000000000001","requestNo":"ZL20260930000001",
                 "kind":"ISSUE","origin":"WORKSHOP_REQUEST","status":"DONE","rowVersion":3,
                 "lines":[{"id":"00000000-0000-4000-8000-000000000002","lineNo":1,
                   "goodsId":"00000000-0000-4000-8000-000000000004","requestedQty":12.50,"fulfilledQty":12.50}],
                 "documents":[],"allowedActions":[]}
                """;
        RequisitionView restored = new ObjectMapper().findAndRegisterModules().readValue(receipt, RequisitionView.class);
        assertEquals("DONE", restored.status());
        assertEquals(new BigDecimal("12.50"), restored.lines().getFirst().fulfilledQty());
        assertNull(restored.lines().getFirst().issueMethod());
    }

    private String captured(List<MaterialSetup> setup) throws Exception {
        WorkshopMaterialCommandLedger ledger = mock(WorkshopMaterialCommandLedger.class);
        Object[] captured = new Object[1];
        when(ledger.execute(eq("REQUISITION_FULFIL"), eq(KEY), any(), eq(RequisitionView.class), any()))
                .thenAnswer(invocation -> { captured[0] = invocation.getArgument(2); return null; });
        WorkshopMaterialRequisitionService service = new WorkshopMaterialRequisitionService(
                null, null, null, ledger, null, null, null, null, null, null, null);
        service.fulfil(REQUEST, new FulfilRequest(2L,
                List.of(new FulfilLine(LINE, LEAF, new BigDecimal("12.50"))), null, KEY, setup));
        return new ObjectMapper().findAndRegisterModules().writeValueAsString(captured[0]);
    }
}
