package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import com.uten.imp.features.stock.dto.WeightInput;
import com.uten.imp.features.stock.weight.SourceKind;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * ADR-135 仓库单据称重采集的纯函数契约: 千克输入口径、领料出库重量合并与请求哈希、批量出库逐行重量、
 * 退料收料重量与确认哈希、审核时登记的观测种类、出库核对指纹。
 */
class StockDocWeightCaptureContractTest {

    private static final UUID ITEM_A = new UUID(0, 1);
    private static final UUID ITEM_B = new UUID(0, 2);

    @Test
    void weightInputIsKilogramsWithFourDecimalsAndZeroMeansNotWeighed() {
        assertNull(WeightInput.kg(null, "重量"));
        assertNull(WeightInput.kg(new BigDecimal("0.0000"), "重量"), "0 = 没称");
        assertEquals(new BigDecimal("12.5000"), WeightInput.kg(new BigDecimal("12.50"), "重量"));
        assertEquals(new BigDecimal("0.0001"), WeightInput.kg(new BigDecimal("0.000100"), "重量"),
                "去尾零后不超过 4 位小数就收");
        assertValidation(() -> WeightInput.kg(new BigDecimal("-1"), "第 1 行实称重量"), "第 1 行实称重量");
        assertValidation(() -> WeightInput.kg(new BigDecimal("0.00001"), "重量"), "4 位小数");
        assertValidation(() -> WeightInput.kg(new BigDecimal("100000000000000"), "重量"), "范围");
        assertEquals("12.5", WeightInput.text(new BigDecimal("12.5000")));
        assertEquals("", WeightInput.text(null));
    }

    @Test
    void issueLinesForTheSameItemSumWeightsAndOrQtyFromWeight() {
        StockDocIssueRequest request = request(
                line(ITEM_B, "1", null, null),
                line(ITEM_A, "2", "1.25", false),
                line(ITEM_A, "3", "0.75", true));

        StockDocIssueRequest canonical =
                StockDocService.canonicalIssueRequest(request, items(), false);

        assertEquals(List.of(ITEM_A, ITEM_B),
                canonical.getLines().stream().map(StockDocIssueRequest.Line::getItemId).toList(),
                "按行号排好序");
        StockDocIssueRequest.Line merged = canonical.getLines().getFirst();
        assertEquals(0, new BigDecimal("5").compareTo(merged.getQty()));
        assertEquals(0, new BigDecimal("2").compareTo(merged.getWeightKg()));
        assertTrue(merged.getQtyFromWeight(), "任一行按称重推算, 整行都算推算");
        assertNull(canonical.getLines().getLast().getWeightKg());
        assertFalse(canonical.getLines().getLast().getQtyFromWeight());
    }

    @Test
    void mixingWeighedAndUnweighedRowsOfOneItemIsRejected() {
        StockDocIssueRequest request = request(
                line(ITEM_A, "2", "1.25", null),
                line(ITEM_A, "3", null, null));

        assertValidation(() -> StockDocService.canonicalIssueRequest(request, items(), false), "都填实称重量");
        StockDocIssueRequest zero = request(
                line(ITEM_A, "2", "1.25", null),
                line(ITEM_A, "3", "0", null));
        assertValidation(() -> StockDocService.canonicalIssueRequest(zero, items(), false), "都填实称重量");
    }

    @Test
    void cancellingAnIssueNeverAcceptsWeights() {
        assertValidation(() -> StockDocService.canonicalIssueRequest(
                request(line(ITEM_A, "1", "0.5", null)), items(), true), "自动退回");
        assertValidation(() -> StockDocService.canonicalIssueRequest(
                request(line(ITEM_A, "1", null, true)), items(), true), "自动退回");
        StockDocIssueRequest plain = StockDocService.canonicalIssueRequest(
                request(line(ITEM_A, "1", "0", false)), items(), true);
        assertNull(plain.getLines().getFirst().getWeightKg(), "填 0 等于没称, 取消出库可以照常提交");
    }

    @Test
    void issueCaptureFingerprintIsNullWithoutWeightsAndStableAcrossScale() {
        StockDocIssueRequest unweighed = StockDocService.canonicalIssueRequest(
                request(line(ITEM_A, "1", null, null), line(ITEM_B, "2", "0", false)), items(), false);
        assertNull(StockDocService.issueCaptureFingerprint(unweighed), "没称重时台账哈希与原口径一致");

        String weighed = StockDocService.issueCaptureFingerprint(StockDocService.canonicalIssueRequest(
                request(line(ITEM_A, "1", "1.50", null)), items(), false));
        String sameWeight = StockDocService.issueCaptureFingerprint(StockDocService.canonicalIssueRequest(
                request(line(ITEM_A, "1", "1.5000", false)), items(), false));
        String otherWeight = StockDocService.issueCaptureFingerprint(StockDocService.canonicalIssueRequest(
                request(line(ITEM_A, "1", "1.6", null)), items(), false));
        String fromWeight = StockDocService.issueCaptureFingerprint(StockDocService.canonicalIssueRequest(
                request(line(ITEM_A, "1", "1.5", true)), items(), false));

        assertEquals(weighed, sameWeight);
        assertNotEquals(weighed, otherWeight);
        assertNotEquals(weighed, fromWeight);
        assertThat(weighed).contains(ITEM_A + "|1.5|false");
    }

    @Test
    void batchWeightsAreNormalizedDedupedAndAttachedToRemainingLinesOnly() {
        Map<UUID, StockDocIssueBatchRequest.ItemWeight> weights = StockDocService.batchIssueWeights(List.of(
                new StockDocIssueBatchRequest.ItemWeight(ITEM_A, new BigDecimal("2.50"), null),
                new StockDocIssueBatchRequest.ItemWeight(ITEM_B, BigDecimal.ZERO, false)));
        assertEquals(List.of(ITEM_A), List.copyOf(weights.keySet()), "0 且不按称重推算的条目丢弃");
        assertEquals(new BigDecimal("2.5000"), weights.get(ITEM_A).weightKg());

        assertValidation(() -> StockDocService.batchIssueWeights(List.of(
                new StockDocIssueBatchRequest.ItemWeight(ITEM_A, BigDecimal.ONE, null),
                new StockDocIssueBatchRequest.ItemWeight(ITEM_A, BigDecimal.TEN, null))), "只能填一次");
        assertValidation(() -> StockDocService.batchIssueWeights(List.of(
                new StockDocIssueBatchRequest.ItemWeight(null, BigDecimal.ONE, null))), "缺少领料明细");
        assertTrue(StockDocService.batchIssueWeights(null).isEmpty());

        StockDocIssueRequest.Line remaining = line(ITEM_A, "4", null, null);
        StockDocIssueRequest.Line other = line(ITEM_B, "1", null, null);
        StockDocService.attachBatchWeights(List.of(remaining, other), weights);
        assertEquals(new BigDecimal("2.5000"), remaining.getWeightKg());
        assertFalse(remaining.getQtyFromWeight());
        assertNull(other.getWeightKg());
    }

    @Test
    void materialReturnWeightsJoinTheReceivingHashOnlyWhenEntered() {
        UUID document = UUID.randomUUID();
        UUID source = UUID.randomUUID();
        UUID received = UUID.randomUUID();
        Map<UUID, BigDecimal> none = StockDocService.materialReturnWeights(List.of(
                new ProductionMaterialReturnConfirmRequest.Line(ITEM_A, BigDecimal.ZERO)));
        assertTrue(none.isEmpty());
        String legacy = com.uten.imp.common.util.CanonicalFingerprint.sha256(List.of(
                "MATERIAL-RETURN-RECEIVING-V1", document.toString(), source.toString(), received.toString()));
        assertEquals(legacy, StockDocService.materialReturnReceivingHash(document, source, received, none),
                "不带重量的确认哈希保持原口径, 已有确认键重放不受影响");

        Map<UUID, BigDecimal> weighed = StockDocService.materialReturnWeights(List.of(
                new ProductionMaterialReturnConfirmRequest.Line(ITEM_B, new BigDecimal("3.20")),
                new ProductionMaterialReturnConfirmRequest.Line(ITEM_A, new BigDecimal("1.5"))));
        assertEquals(List.of(ITEM_A, ITEM_B), List.copyOf(weighed.keySet()), "按明细 id 排序");
        String withWeights = StockDocService.materialReturnReceivingHash(document, source, received, weighed);
        assertNotEquals(legacy, withWeights);
        Map<UUID, BigDecimal> reordered = StockDocService.materialReturnWeights(List.of(
                new ProductionMaterialReturnConfirmRequest.Line(ITEM_A, new BigDecimal("1.50")),
                new ProductionMaterialReturnConfirmRequest.Line(ITEM_B, new BigDecimal("3.2"))));
        assertEquals(withWeights, StockDocService.materialReturnReceivingHash(document, source, received, reordered));
        assertEquals("{\"" + ITEM_A + "\":1.5,\"" + ITEM_B + "\":3.2}",
                StockDocService.receivedWeightsJson(weighed));
        assertEquals("{}", StockDocService.receivedWeightsJson(none));

        assertValidation(() -> StockDocService.materialReturnWeights(List.of(
                new ProductionMaterialReturnConfirmRequest.Line(ITEM_A, BigDecimal.ONE),
                new ProductionMaterialReturnConfirmRequest.Line(ITEM_A, BigDecimal.TEN))), "只能填一次");
        assertValidation(() -> StockDocService.materialReturnWeights(List.of(
                new ProductionMaterialReturnConfirmRequest.Line(ITEM_A, new BigDecimal("-0.1")))), "不能小于 0");
        assertNull(new ProductionMaterialReturnConfirmRequest(received, "confirm-key-01").lines(),
                "两参构造保持不带重量");
    }

    @Test
    void approvalObservationKindFollowsTheDocumentType() {
        assertEquals(SourceKind.OTHER_IN, StockDocService.observedKind("OTHER_IN"));
        assertEquals(SourceKind.OTHER_IN, StockDocService.observedKind("FINISHED_IN"));
        assertEquals(SourceKind.OTHER_OUT, StockDocService.observedKind("OTHER_OUT"));
        assertEquals(SourceKind.OTHER_OUT, StockDocService.observedKind("WASTE"));
        assertEquals(SourceKind.OTHER_OUT, StockDocService.observedKind("FINISHED_OUT"));
        assertEquals(SourceKind.TRANSFER, StockDocService.observedKind("TRANSFER"));
        assertNull(StockDocService.observedKind("CHECK"), "盘点的观测在盘点定重时单独登记");
        assertNull(StockDocService.observedKind("DRAW"), "领料按每次出库流水登记");
        assertNull(StockDocService.observedKind("WDRAW"));
        assertNull(StockDocService.observedKind(null));
    }

    @Test
    void outboundReviewTokenCoversWeightCaptureFields() {
        StockDocument document = new StockDocument();
        document.setId(UUID.randomUUID());
        document.setDocType("OTHER_OUT");
        StockDocumentItem item = new StockDocumentItem();
        item.setId(ITEM_A);
        item.setQty(BigDecimal.TEN);
        item.setWeight(new BigDecimal("2.5"));
        String token = StockDocOutboundReviewFingerprint.of(document, List.of(item));

        item.setQtyFromWeight(true);
        String fromWeight = StockDocOutboundReviewFingerprint.of(document, List.of(item));
        assertNotEquals(token, fromWeight);
        item.setCountWeight(new BigDecimal("1"));
        assertNotEquals(fromWeight, StockDocOutboundReviewFingerprint.of(document, List.of(item)));
    }

    @Test
    void checkCountWeightPostsAfterTheSurplusMovementEvenWhenSurplusIsZero() throws Exception {
        Path direct = Path.of("src/main/java/com/uten/imp/features/stock/StockDocService.java");
        Path source = Files.exists(direct) ? direct : Path.of("server").resolve(direct);
        String java = Files.readString(source, StandardCharsets.UTF_8).replace("\r\n", "\n");
        int start = java.indexOf("private void applyCheckLine(");
        int end = java.indexOf("private static void requireCountWeightAllowed(", start);
        String method = java.substring(start, end);

        assertThat(method).doesNotContain("continue");
        assertThat(method.indexOf("move(d, it, T_CHECK_LOSS"))
                .isNotNegative()
                .isLessThan(method.indexOf("setWeight("));
        assertThat(method.indexOf("reverseSetWeight("))
                .isGreaterThan(method.indexOf("move(d, it, T_CHECK_LOSS"));
        assertThat(java).contains("applyIssueMovement(d, item, line.getQty(), ts, +1, posted.eventId(), line.getWeightKg())")
                .contains("applyIssueMovement(d, item, line.getQty(), ts, -1, null, null)");
    }

    private static List<StockDocumentItem> items() {
        List<StockDocumentItem> items = new ArrayList<>();
        StockDocumentItem b = new StockDocumentItem();
        b.setId(ITEM_B);
        b.setLineNo(2);
        items.add(b);
        StockDocumentItem a = new StockDocumentItem();
        a.setId(ITEM_A);
        a.setLineNo(1);
        items.add(a);
        return items;
    }

    private static StockDocIssueRequest request(StockDocIssueRequest.Line... lines) {
        StockDocIssueRequest request = new StockDocIssueRequest();
        request.setIdempotencyKey("issue-weight-key");
        request.setLines(List.of(lines));
        return request;
    }

    private static StockDocIssueRequest.Line line(UUID itemId, String qty, String weightKg, Boolean fromWeight) {
        StockDocIssueRequest.Line line = new StockDocIssueRequest.Line();
        line.setItemId(itemId);
        line.setQty(new BigDecimal(qty));
        line.setWeightKg(weightKg == null ? null : new BigDecimal(weightKg));
        line.setQtyFromWeight(fromWeight);
        return line;
    }

    private static void assertValidation(org.junit.jupiter.api.function.Executable call, String messagePart) {
        ApiException failure = assertThrows(ApiException.class, call);
        assertEquals(ErrorCode.VALIDATION_FAILED, failure.getCode());
        assertThat(failure.getMessage()).contains(messagePart);
    }
}
