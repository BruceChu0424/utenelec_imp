package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** 领料任务中心批量出库的纯函数契约：子幂等键、出库备注合并、逐单错误包装、剩余行。 */
class StockDocIssueBatchContractTest {

    @Test
    void childKeyIsSha256HexScopedToActorBatchAndDocument() {
        UUID actor = UUID.randomUUID();
        UUID otherActor = UUID.randomUUID();
        UUID document = UUID.randomUUID();
        UUID otherDocument = UUID.randomUUID();

        String key = StockDocService.batchChildIdempotencyKey(actor, "batch-key-0001", document);

        assertEquals(64, key.length(), "SHA-256 十六进制固定 64 位，低于台账幂等键 128 上限");
        assertTrue(key.matches("[0-9a-f]{64}"), key);
        assertEquals(key, StockDocService.batchChildIdempotencyKey(actor, "batch-key-0001", document),
                "同人同批量键同单据必须稳定，响应丢失重试才能命中重放");
        assertNotEquals(key, StockDocService.batchChildIdempotencyKey(otherActor, "batch-key-0001", document),
                "不同操作人复用同一批量键不得撞出「相同幂等键对应不同领退料请求」");
        assertNotEquals(key, StockDocService.batchChildIdempotencyKey(actor, "batch-key-0002", document));
        assertNotEquals(key, StockDocService.batchChildIdempotencyKey(actor, "batch-key-0001", otherDocument));
        assertEquals(64, StockDocService.batchChildIdempotencyKey(actor, "k".repeat(128), document).length(),
                "最长批量键也压缩到 64 位");
    }

    @Test
    void mergeIssueRemarkDedupsWholeEntriesNotSubstrings() {
        assertEquals("AB", StockDocService.mergeIssueRemark(null, "AB"));
        assertEquals("AB", StockDocService.mergeIssueRemark("   ", " AB "));
        assertEquals("AB；A", StockDocService.mergeIssueRemark("AB", "A"),
                "此前 contains 判重会把「A」当成「AB」的重复而丢失");
        assertEquals("AB；A", StockDocService.mergeIssueRemark("AB；A", "A"));
        assertEquals("AB；A", StockDocService.mergeIssueRemark("AB；A", " AB "));
        assertEquals("AB；A", StockDocService.mergeIssueRemark("AB；A", "A"));
        assertNull(StockDocService.mergeIssueRemark(null, "  "));
        assertEquals("旧备注", StockDocService.mergeIssueRemark("旧备注", null));
    }

    @Test
    void mergeIssueRemarkCapsNoteAt200AndTotalAt500() {
        String longNote = "备".repeat(250);
        assertEquals(200, StockDocService.mergeIssueRemark(null, longNote).length());

        String current = "x".repeat(495);
        String merged = StockDocService.mergeIssueRemark(current, "追加的出库备注");
        assertEquals(500, merged.length(), "495 + 「；」 + 7 字 = 503 → 截断到 500");
        assertTrue(merged.startsWith(current + "；"));
        assertEquals(merged, StockDocService.mergeIssueRemark(merged, "追加的出库备注"),
                "截断后的重放不再增长");
    }

    @Test
    void batchFailureCarriesBillNumberOnceWithSameCode() {
        ApiException wrapped = StockDocService.batchDocumentFailure(
                "LL-2609-0001", new ApiException(ErrorCode.CONFLICT, "本仓剩余可领数量不足"));

        assertEquals(ErrorCode.CONFLICT, wrapped.getCode(), "错误码不变，前端按码分流");
        assertEquals("领料单 LL-2609-0001：本仓剩余可领数量不足", wrapped.getMessage());
        assertSame(wrapped, StockDocService.batchDocumentFailure("LL-2609-0001", wrapped),
                "已带单号的异常不重复包装");
        assertEquals("领料单 LL-2609-0002：资源不存在",
                StockDocService.batchDocumentFailure("LL-2609-0002", new ApiException(ErrorCode.NOT_FOUND))
                        .getMessage());
    }

    @Test
    void remainingIssueLinesSkipFinishedRowsAndUseRemainingQuantity() {
        StockDocumentItem open = new StockDocumentItem();
        open.setQty(new BigDecimal("10"));
        open.setIssuedQty(new BigDecimal("4"));
        StockDocumentItem untouched = new StockDocumentItem();
        untouched.setQty(new BigDecimal("3"));
        untouched.setIssuedQty(null);
        StockDocumentItem finished = new StockDocumentItem();
        finished.setQty(new BigDecimal("5"));
        finished.setIssuedQty(new BigDecimal("5"));

        List<StockDocIssueRequest.Line> lines =
                StockDocService.remainingIssueLines(List.of(open, untouched, finished));

        assertEquals(2, lines.size());
        assertEquals(open.getId(), lines.get(0).getItemId());
        assertEquals(0, new BigDecimal("6").compareTo(lines.get(0).getQty()));
        assertEquals(untouched.getId(), lines.get(1).getItemId());
        assertEquals(0, new BigDecimal("3").compareTo(lines.get(1).getQty()));
        assertTrue(StockDocService.remainingIssueLines(List.of(finished)).isEmpty(),
                "已出完的单据没有剩余行 → 批量跳过/重放");
    }
}
