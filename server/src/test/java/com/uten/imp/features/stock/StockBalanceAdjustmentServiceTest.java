package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.dto.StockBalanceAdjustmentRequest;
import com.uten.imp.features.stock.dto.StockBalanceAdjustmentResult;
import com.uten.imp.features.stock.dto.StockDocDetail;
import com.uten.imp.features.stock.dto.StockDocItemDto;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class StockBalanceAdjustmentServiceTest {

    @Mock
    private StockBalanceRepository balanceRepo;
    @Mock
    private StockService stockService;
    @Mock
    private StockDocService stockDocService;
    @Mock
    private TxSessionVars tx;

    @Test
    void createsAndApprovesTraceableCheckDocument() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        UUID documentId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        Instant adjustedAt = Instant.parse("2026-07-31T01:00:00Z");

        StockBalance balance = balance(warehouseId, goodsId, colorId, "10");
        when(balanceRepo.findByWarehouseIdAndGoodsIdAndColorId(
                warehouseId, goodsId, colorId)).thenReturn(Optional.of(balance));

        StockDocDetail draft = org.mockito.Mockito.mock(StockDocDetail.class);
        StockDocDetail approved = org.mockito.Mockito.mock(StockDocDetail.class);
        when(draft.getId()).thenReturn(documentId);
        when(approved.getId()).thenReturn(documentId);
        when(approved.getBillNo()).thenReturn("PD26070001");
        when(approved.getMakerId()).thenReturn(employeeId);
        when(approved.getMakerName()).thenReturn("库存主管");
        when(approved.getCreatedAt()).thenReturn(adjustedAt);
        when(stockDocService.findAuthorizedBalanceAdjustment(anyString()))
                .thenReturn(Optional.empty());
        when(stockDocService.createAuthorizedBalanceAdjustment(any(), anyString()))
                .thenReturn(draft);
        when(stockDocService.approve(documentId)).thenReturn(approved);

        StockBalanceAdjustmentService service =
                new StockBalanceAdjustmentService(
                        balanceRepo, stockService, stockDocService, tx);
        StockBalanceAdjustmentResult result =
                service.adjust(request(warehouseId, goodsId, colorId, "10", "7", "周期抽盘发现少件"));

        ArgumentCaptor<StockDocSaveRequest> captor =
                ArgumentCaptor.forClass(StockDocSaveRequest.class);
        verify(stockDocService).createAuthorizedBalanceAdjustment(
                captor.capture(), eq("balance-adjust-test-key"));
        StockDocSaveRequest document = captor.getValue();
        assertEquals("CHECK", document.getDocType());
        assertEquals(warehouseId, document.getWarehouseId());
        assertTrue(document.getRemark().contains("周期抽盘发现少件"));
        assertEquals(1, document.getItems().size());
        assertEquals(new BigDecimal("10"), document.getItems().getFirst().getQty());
        assertEquals(new BigDecimal("7"), document.getItems().getFirst().getCountQty());
        assertEquals(document.getRemark(), document.getItems().getFirst().getRemark());

        assertEquals(documentId, result.documentId());
        assertEquals(new BigDecimal("-3"), result.deltaQty());
        assertEquals("库存主管", result.adjustedByName());
        assertEquals(adjustedAt, result.adjustedAt());
    }

    @Test
    void rejectsStaleDisplayedQuantityBeforeCreatingDocument() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        StockBalance balance = balance(warehouseId, goodsId, null, "12");
        when(balanceRepo.findByWarehouseIdAndGoodsIdAndColorId(
                warehouseId, goodsId, null)).thenReturn(Optional.of(balance));
        when(stockDocService.findAuthorizedBalanceAdjustment(anyString()))
                .thenReturn(Optional.empty());

        StockBalanceAdjustmentService service =
                new StockBalanceAdjustmentService(
                        balanceRepo, stockService, stockDocService, tx);
        ApiException error = assertThrows(
                ApiException.class,
                () -> service.adjust(request(
                        warehouseId, goodsId, null, "10", "8", "周期盘点")));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertTrue(error.getMessage().contains("请刷新"));
        verify(stockDocService, never()).createAuthorizedBalanceAdjustment(any(), anyString());
    }

    @Test
    void rejectsNegativeOrUnchangedTarget() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        StockBalanceAdjustmentService service =
                new StockBalanceAdjustmentService(
                        balanceRepo, stockService, stockDocService, tx);

        ApiException negative = assertThrows(
                ApiException.class,
                () -> service.adjust(request(
                        warehouseId, goodsId, null, "1", "-1", "错误修正")));
        assertEquals(ErrorCode.VALIDATION_FAILED, negative.getCode());

        StockBalance balance = balance(warehouseId, goodsId, null, "1");
        when(balanceRepo.findByWarehouseIdAndGoodsIdAndColorId(
                warehouseId, goodsId, null)).thenReturn(Optional.of(balance));
        when(stockDocService.findAuthorizedBalanceAdjustment(anyString()))
                .thenReturn(Optional.empty());
        ApiException unchanged = assertThrows(
                ApiException.class,
                () -> service.adjust(request(
                        warehouseId, goodsId, null, "1", "1", "重复提交")));
        assertEquals(ErrorCode.VALIDATION_FAILED, unchanged.getCode());
        verify(stockDocService, never()).createAuthorizedBalanceAdjustment(any(), anyString());
    }

    @Test
    void replaysSameSuccessfulAdjustmentForRetryWithoutWritingAgain() {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID documentId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        Instant adjustedAt = Instant.parse("2026-07-31T01:00:00Z");

        StockDocItemDto item = org.mockito.Mockito.mock(StockDocItemDto.class);
        when(item.getGoodsId()).thenReturn(goodsId);
        when(item.getQty()).thenReturn(new BigDecimal("10"));
        when(item.getCountQty()).thenReturn(new BigDecimal("7"));

        StockDocDetail existing = org.mockito.Mockito.mock(StockDocDetail.class);
        when(existing.getId()).thenReturn(documentId);
        when(existing.getBillNo()).thenReturn("PD26070001");
        when(existing.getWarehouseId()).thenReturn(warehouseId);
        when(existing.getRemark()).thenReturn("[授权余额调整] 周期抽盘发现少件");
        when(existing.getItems()).thenReturn(java.util.List.of(item));
        when(existing.getMakerId()).thenReturn(employeeId);
        when(existing.getMakerName()).thenReturn("库存主管");
        when(existing.getCreatedAt()).thenReturn(adjustedAt);
        when(stockDocService.findAuthorizedBalanceAdjustment("balance-adjust-test-key"))
                .thenReturn(Optional.of(existing));

        StockBalanceAdjustmentService service =
                new StockBalanceAdjustmentService(
                        balanceRepo, stockService, stockDocService, tx);
        StockBalanceAdjustmentResult result =
                service.adjust(request(
                        warehouseId, goodsId, null, "10", "7", "周期抽盘发现少件"));

        assertEquals(documentId, result.documentId());
        assertEquals(new BigDecimal("-3"), result.deltaQty());
        assertEquals("库存主管", result.adjustedByName());
        verify(stockDocService, never())
                .createAuthorizedBalanceAdjustment(any(), anyString());
        verify(stockDocService, never()).approve(any());
        verifyNoInteractions(balanceRepo);
    }

    private static StockBalanceAdjustmentRequest request(
            UUID warehouseId,
            UUID goodsId,
            UUID colorId,
            String expectedQty,
            String targetQty,
            String reason) {
        StockBalanceAdjustmentRequest request = new StockBalanceAdjustmentRequest();
        request.setIdempotencyKey("balance-adjust-test-key");
        request.setWarehouseId(warehouseId);
        request.setGoodsId(goodsId);
        request.setColorId(colorId);
        request.setExpectedQty(new BigDecimal(expectedQty));
        request.setTargetQty(new BigDecimal(targetQty));
        request.setReason(reason);
        return request;
    }

    private static StockBalance balance(
            UUID warehouseId, UUID goodsId, UUID colorId, String qty) {
        StockBalance balance = new StockBalance();
        balance.setWarehouseId(warehouseId);
        balance.setGoodsId(goodsId);
        balance.setColorId(colorId);
        balance.setQty(new BigDecimal(qty));
        return balance;
    }
}
