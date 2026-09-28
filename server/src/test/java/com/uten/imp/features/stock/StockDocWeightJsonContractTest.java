package com.uten.imp.features.stock;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.json.JsonMapper;
import com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest;
import com.uten.imp.features.stock.dto.StockBalanceAdjustmentRequest;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import com.uten.imp.features.stock.dto.StockDocItemDto;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * ADR-135 仓库单据称重的 JSON 字段名契约(服务端 <-> 客户端逐字段对齐)。
 *
 * <p>请求体按客户端实际发出的形状原样书写(lib/features/warehouse/repositories/stock_doc_repository.dart、
 * pages/stock_doc_edit_page.dart、pages/stock_doc_detail_page.dart、repositories/production_draw_task_repository.dart、
 * lib/features/stock/repositories/stock_query_repository.dart), 用「未知字段即失败」的映射器反序列化:
 * 线上 Jackson 默认静默丢弃未知字段, 名字差一个字母就等于没传重量, 只能在这里拦住。
 * 返回体一侧锁住客户端 StockDocItem.fromJson 读取的重量字段名与正负口径。
 */
class StockDocWeightJsonContractTest {

    private static final ObjectMapper STRICT = JsonMapper.builder()
            .findAndAddModules()
            .enable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
            .build();

    private static final UUID ITEM = new UUID(0, 1);
    private static final UUID GOODS = new UUID(0, 2);
    private static final UUID COLOR = new UUID(0, 3);
    private static final UUID UNIT = new UUID(0, 4);
    private static final UUID WAREHOUSE = new UUID(0, 5);
    private static final UUID DOC = new UUID(0, 6);

    @Test
    void drawIssueLineCarriesWeightKgAndQtyFromWeightAndCancelCarriesQuantitiesOnly() throws Exception {
        StockDocIssueRequest issue = STRICT.readValue("""
                {"lines":[{"itemId":"%s","qty":5.0,"weightKg":0.025,"qtyFromWeight":true}],
                 "idempotencyKey":"DRAW-ISSUE-0123456789abcdef","reason":"本次出库"}
                """.formatted(ITEM), StockDocIssueRequest.class);
        StockDocIssueRequest.Line line = issue.getLines().getFirst();
        assertEquals(ITEM, line.getItemId());
        assertThat(line.getWeightKg()).isEqualByComparingTo("0.025");
        assertEquals(Boolean.TRUE, line.getQtyFromWeight());

        StockDocIssueRequest cancel = STRICT.readValue("""
                {"lines":[{"itemId":"%s","qty":2.0}],
                 "idempotencyKey":"DRAW-ISSUE-REVERSE-0123456789abcdef","reason":"领多了"}
                """.formatted(ITEM), StockDocIssueRequest.class);
        assertNull(cancel.getLines().getFirst().getWeightKg());
        assertNull(cancel.getLines().getFirst().getQtyFromWeight());
    }

    @Test
    void batchIssueWeightsBindByItemId() throws Exception {
        StockDocIssueBatchRequest batch = STRICT.readValue("""
                {"idempotencyKey":"batch-0123456789","docIds":["%s"],
                 "weights":[{"itemId":"%s","weightKg":1.25,"qtyFromWeight":false}],"reason":"统一备注"}
                """.formatted(DOC, ITEM), StockDocIssueBatchRequest.class);
        StockDocIssueBatchRequest.ItemWeight weight = batch.getWeights().getFirst();
        assertEquals(ITEM, weight.itemId());
        assertThat(weight.weightKg()).isEqualByComparingTo("1.25");
        assertEquals(Boolean.FALSE, weight.qtyFromWeight());

        StockDocIssueBatchRequest unweighed = STRICT.readValue("""
                {"idempotencyKey":"batch-0123456789","docIds":["%s"]}
                """.formatted(DOC), StockDocIssueBatchRequest.class);
        assertTrue(StockDocService.batchIssueWeights(unweighed.getWeights()).isEmpty(), "没带 weights = 都没称");
    }

    @Test
    void materialReturnConfirmLinesAreOptionalAndMissingMeansNoWeights() throws Exception {
        ProductionMaterialReturnConfirmRequest weighed = STRICT.readValue("""
                {"warehouseId":"%s","idempotencyKey":"material-return-confirm-0123456789abcdef",
                 "lines":[{"itemId":"%s","weightKg":0.2}]}
                """.formatted(WAREHOUSE, ITEM), ProductionMaterialReturnConfirmRequest.class);
        assertEquals(WAREHOUSE, weighed.warehouseId());
        assertEquals(Map.of(ITEM, new BigDecimal("0.2000")),
                StockDocService.materialReturnWeights(weighed.lines()));

        ProductionMaterialReturnConfirmRequest plain = STRICT.readValue("""
                {"warehouseId":"%s","idempotencyKey":"material-return-confirm-0123456789abcdef"}
                """.formatted(WAREHOUSE), ProductionMaterialReturnConfirmRequest.class);
        assertNull(plain.lines());
        assertTrue(StockDocService.materialReturnWeights(plain.lines()).isEmpty());
        assertEquals(StockDocService.materialReturnReceivingHash(DOC, WAREHOUSE, WAREHOUSE, Map.of()),
                StockDocService.materialReturnReceivingHash(DOC, WAREHOUSE, WAREHOUSE,
                        StockDocService.materialReturnWeights(plain.lines())),
                "没称的收仓确认与原口径同一哈希");
    }

    @Test
    void stockDocSaveItemsCarryWeightCountWeightAndQtyFromWeight() throws Exception {
        StockDocSaveRequest otherIn = STRICT.readValue("""
                {"docType":"OTHER_IN","billDate":"2026-09-28","warehouseId":"%s","remark":null,
                 "items":[{"goodsId":"%s","colorId":"%s","unitId":"%s","unitRate":1,"qty":3,
                           "weight":12.5,"qtyFromWeight":true}]}
                """.formatted(WAREHOUSE, GOODS, COLOR, UNIT), StockDocSaveRequest.class);
        StockDocItemLine line = otherIn.getItems().getFirst();
        assertThat(line.getWeight()).isEqualByComparingTo("12.5");
        assertEquals(Boolean.TRUE, line.getQtyFromWeight());
        assertNull(line.getCountWeight());

        StockDocSaveRequest check = STRICT.readValue("""
                {"docType":"CHECK","billDate":"2026-09-28","warehouseId":"%s",
                 "items":[{"goodsId":"%s","unitRate":1,"qty":10,"countQty":8,"surplusQty":-2,
                           "countWeight":0.64,"qtyFromWeight":true}]}
                """.formatted(WAREHOUSE, GOODS), StockDocSaveRequest.class);
        StockDocItemLine counted = check.getItems().getFirst();
        assertThat(counted.getCountWeight()).isEqualByComparingTo("0.64");
        assertNull(counted.getWeight());
        assertEquals(Boolean.TRUE, counted.getQtyFromWeight());
    }

    @Test
    void balanceAdjustmentAcceptsTargetWeightKg() throws Exception {
        StockBalanceAdjustmentRequest adjust = STRICT.readValue("""
                {"idempotencyKey":"stock-balance-adjust-0123456789abcdef","warehouseId":"%s","goodsId":"%s",
                 "colorId":"%s","expectedQty":10,"targetQty":"10","targetWeightKg":5.25,"reason":"复称"}
                """.formatted(WAREHOUSE, GOODS, COLOR), StockBalanceAdjustmentRequest.class);
        assertThat(adjust.getTargetWeightKg()).isEqualByComparingTo("5.25");
        assertThat(adjust.getTargetQty()).isEqualByComparingTo("10");
    }

    @Test
    void itemResponseEmitsTheWeightFieldsTheClientReadsAndIssuedWeightIsPositive() throws Exception {
        StockDocItemDto item = new StockDocItemDto(
                ITEM, 1, GOODS, "G-1", "螺丝", null, null, COLOR,
                UNIT, BigDecimal.ONE, new BigDecimal("10"), null, new BigDecimal("10"),
                new BigDecimal("1.5"), null, null, null, BigDecimal.ZERO,
                null, null, null, null, null, null,
                null, null, null, null, new BigDecimal("5"), false, new BigDecimal("10"),
                true, null, null, new BigDecimal("0.0100"), true);
        Map<String, Object> json = STRICT.convertValue(item, new TypeReference<Map<String, Object>>() {});

        assertThat(json).containsEntry("qtyFromWeight", true)
                .containsEntry("issuedWeightEstimated", true)
                .containsKeys("weight", "countWeight", "bookWeight", "issuedWeightKg");
        // 已出库重量恒为正数(领料 = 发出减取消), 客户端原样显示。
        assertThat(new BigDecimal(json.get("issuedWeightKg").toString())).isEqualByComparingTo("0.01");
        assertFalse(json.containsKey("price"), "仓库实物行不序列化单价");
    }
}
