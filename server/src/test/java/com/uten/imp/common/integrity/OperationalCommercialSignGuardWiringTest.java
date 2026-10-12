package com.uten.imp.common.integrity;

import org.junit.jupiter.api.Test;
import com.uten.imp.support.DraftMutationSourceContract;
import com.uten.imp.common.finance.ProcurementQuantities;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class OperationalCommercialSignGuardWiringTest {

    private static final Path FEATURE_SOURCE =
            Path.of("src/main/java/com/uten/imp/features");
    private static final String STORED_GUARD_CALL =
            "requireNonNegativeStoredCommercial(r, items);";

    @Test
    void allThreeOperationalDocumentsValidateRequestsAndStoredState() throws IOException {
        assertPurchaseWired(read("purchase/receipt/PurchaseReceiptService.java"), "approveReceipt");
        assertPurchaseWired(read("purchase/ret/PurchaseReturnService.java"), "approveReturn");
        assertWired(read("sales/ret/SalesReturnService.java"));
    }

    private static void assertPurchaseWired(String source, String approvalKernel) {
        String save = DraftMutationSourceContract.method(source, "saveItems");
        String compact = save.replaceAll("\\s+", "");
        assertThat(compact).contains("getPrice().signum()<0", "ErrorCode.VALIDATION_FAILED", "ProcurementQuantities.of(");
        assertThat(compact.indexOf("getPrice().signum()<0")).isLessThan(compact.indexOf("itemRepo.save("));
        String stored = DraftMutationSourceContract.method(source, "requireNonNegativeStoredCommercial");
        assertThat(stored).contains("requireStoredTotals(", "ProcurementQuantities.of(",
                "getPrice()", "getAmountOriginal()", "getAmountLocal()", "ErrorCode.CONFLICT");
        assertThat(DraftMutationSourceContract.methodNamesInvoking(source, "requireNonNegativeStoredCommercial"))
                .containsExactlyInAnyOrder(approvalKernel, "requireReversibleBusiness", "reverse");
    }

    @Test
    void purchaseStoredGuardsRejectNegativeMagnitudeAndKeepGiftOnlyPhysicalFacts() throws Exception {
        var receipt = new com.uten.imp.features.purchase.receipt.PurchaseReceipt();
        receipt.setTotalOriginal(BigDecimal.ZERO); receipt.setTotalLocal(BigDecimal.ZERO);
        var receiptItem = new com.uten.imp.features.purchase.receipt.PurchaseReceiptItem();
        receiptItem.setQuantitySemantics(ProcurementQuantities.EXTRA_GIFT);
        receiptItem.setQty(BigDecimal.ZERO); receiptItem.setGiftQty(BigDecimal.ONE); receiptItem.setUnitRate(BigDecimal.ONE);
        receiptItem.setPrice(BigDecimal.ZERO); receiptItem.setAmountOriginal(BigDecimal.ZERO); receiptItem.setAmountLocal(BigDecimal.ZERO);
        UUID orderSource = UUID.randomUUID(); receiptItem.setOrderItemId(orderSource);
        invokeGuard(com.uten.imp.features.purchase.receipt.PurchaseReceiptService.class, receipt, receiptItem);
        for (String field : List.of("Price", "AmountOriginal", "AmountLocal")) {
            receiptItem.getClass().getMethod("set" + field, BigDecimal.class).invoke(receiptItem, new BigDecimal("-1"));
            assertThat(org.junit.jupiter.api.Assertions.assertThrows(ApiException.class,
                    () -> invokeGuard(com.uten.imp.features.purchase.receipt.PurchaseReceiptService.class, receipt, receiptItem)).getCode())
                    .isEqualTo(ErrorCode.CONFLICT);
            receiptItem.getClass().getMethod("set" + field, BigDecimal.class).invoke(receiptItem, BigDecimal.ZERO);
        }
        assertThat(receiptItem.getOrderItemId()).isEqualTo(orderSource);
        assertThat(receiptItem.getQty()).isZero(); assertThat(receiptItem.getGiftQty()).isEqualByComparingTo("1");
        var returned = new com.uten.imp.features.purchase.ret.PurchaseReturn();
        returned.setTotalOriginal(BigDecimal.ZERO); returned.setTotalLocal(BigDecimal.ZERO);
        var returnItem = new com.uten.imp.features.purchase.ret.PurchaseReturnItem();
        returnItem.setQuantitySemantics(ProcurementQuantities.EXTRA_GIFT);
        returnItem.setQty(BigDecimal.ZERO); returnItem.setGiftQty(BigDecimal.ONE); returnItem.setUnitRate(BigDecimal.ONE);
        returnItem.setPrice(BigDecimal.ZERO); returnItem.setAmountOriginal(BigDecimal.ZERO); returnItem.setAmountLocal(BigDecimal.ZERO);
        UUID receiptSource = UUID.randomUUID(); returnItem.setReceiptItemId(receiptSource);
        invokeGuard(com.uten.imp.features.purchase.ret.PurchaseReturnService.class, returned, returnItem);
        for (String field : List.of("Price", "AmountOriginal", "AmountLocal")) {
            returnItem.getClass().getMethod("set" + field, BigDecimal.class).invoke(returnItem, new BigDecimal("-1"));
            assertThat(org.junit.jupiter.api.Assertions.assertThrows(ApiException.class,
                    () -> invokeGuard(com.uten.imp.features.purchase.ret.PurchaseReturnService.class, returned, returnItem)).getCode())
                    .isEqualTo(ErrorCode.CONFLICT);
            returnItem.getClass().getMethod("set" + field, BigDecimal.class).invoke(returnItem, BigDecimal.ZERO);
        }
        assertThat(returnItem.getReceiptItemId()).isEqualTo(receiptSource);
    }

    @Test
    void purchaseSaveKernelsRejectNegativePriceBeforeAnyLineWrite() throws Exception {
        var receipt = new com.uten.imp.features.purchase.receipt.PurchaseReceipt();
        receipt.setQuantitySemantics(ProcurementQuantities.EXTRA_GIFT); receipt.setExchangeRate(BigDecimal.ONE);
        var receiptLine = new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();
        receiptLine.setGoodsId(UUID.randomUUID()); receiptLine.setQty(BigDecimal.ONE); receiptLine.setPrice(new BigDecimal("-1"));
        var receiptFixture = fixture(com.uten.imp.features.purchase.receipt.PurchaseReceiptService.class);
        assertThat(org.junit.jupiter.api.Assertions.assertThrows(ApiException.class,
                () -> invokeSave(receiptFixture.service(), receipt, receiptLine)).getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
        verify((com.uten.imp.features.purchase.receipt.PurchaseReceiptItemRepository) receiptFixture.items(), never()).save(any());
        var returned = new com.uten.imp.features.purchase.ret.PurchaseReturn();
        returned.setQuantitySemantics(ProcurementQuantities.EXTRA_GIFT); returned.setExchangeRate(BigDecimal.ONE);
        var returnLine = new com.uten.imp.features.purchase.ret.dto.ReturnItemLine();
        returnLine.setGoodsId(UUID.randomUUID()); returnLine.setQty(BigDecimal.ONE); returnLine.setPrice(new BigDecimal("-1"));
        var returnFixture = fixture(com.uten.imp.features.purchase.ret.PurchaseReturnService.class);
        assertThat(org.junit.jupiter.api.Assertions.assertThrows(ApiException.class,
                () -> invokeSave(returnFixture.service(), returned, returnLine)).getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
        verify((com.uten.imp.features.purchase.ret.PurchaseReturnItemRepository) returnFixture.items(), never()).save(any());
    }

    @Test
    void giftOnlySaveKeepsOriginalSourcesAndZeroCommercialAmounts() throws Exception {
        UUID goods = UUID.randomUUID(), unit = UUID.randomUUID(), source = UUID.randomUUID(), currency = UUID.randomUUID();
        var receiptFixture = fixture(com.uten.imp.features.purchase.receipt.PurchaseReceiptService.class);
        prepareSnapshots(receiptFixture, goods, unit, source, currency);
        var receipt = new com.uten.imp.features.purchase.receipt.PurchaseReceipt();
        receipt.setQuantitySemantics(ProcurementQuantities.EXTRA_GIFT); receipt.setCurrencyId(currency); receipt.setExchangeRate(BigDecimal.ONE);
        var line = new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();
        line.setGoodsId(goods); line.setUnitId(unit); line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.ZERO); line.setGiftQty(new BigDecimal("2")); line.setPrice(BigDecimal.ZERO); line.setOrderItemId(source);
        invokeSave(receiptFixture.service(), receipt, line);
        var receiptCaptor = org.mockito.ArgumentCaptor.forClass(com.uten.imp.features.purchase.receipt.PurchaseReceiptItem.class);
        verify((com.uten.imp.features.purchase.receipt.PurchaseReceiptItemRepository) receiptFixture.items()).save(receiptCaptor.capture());
        var saved = receiptCaptor.getValue();
        assertThat(saved.getQty()).isZero(); assertThat(saved.getGiftQty()).isEqualByComparingTo("2");
        assertThat(saved.getAmountOriginal()).isZero(); assertThat(saved.getAmountLocal()).isZero();
        assertThat(saved.getChargedBaseQty()).isZero(); assertThat(saved.getGiftBaseQty()).isEqualByComparingTo("2");
        assertThat(saved.getOrderItemId()).isEqualTo(source);
        var returnFixture = fixture(com.uten.imp.features.purchase.ret.PurchaseReturnService.class);
        prepareSnapshots(returnFixture, goods, unit, source, currency);
        var returned = new com.uten.imp.features.purchase.ret.PurchaseReturn();
        returned.setQuantitySemantics(ProcurementQuantities.EXTRA_GIFT); returned.setExchangeRate(BigDecimal.ONE);
        var returnLine = new com.uten.imp.features.purchase.ret.dto.ReturnItemLine();
        returnLine.setGoodsId(goods); returnLine.setUnitId(unit); returnLine.setUnitRate(BigDecimal.ONE);
        returnLine.setQty(BigDecimal.ZERO); returnLine.setGiftQty(new BigDecimal("2")); returnLine.setPrice(BigDecimal.ZERO); returnLine.setReceiptItemId(source);
        invokeSave(returnFixture.service(), returned, returnLine);
        var returnCaptor = org.mockito.ArgumentCaptor.forClass(com.uten.imp.features.purchase.ret.PurchaseReturnItem.class);
        verify((com.uten.imp.features.purchase.ret.PurchaseReturnItemRepository) returnFixture.items()).save(returnCaptor.capture());
        var savedReturn = returnCaptor.getValue();
        assertThat(savedReturn.getQty()).isZero(); assertThat(savedReturn.getGiftQty()).isEqualByComparingTo("2");
        assertThat(savedReturn.getAmountOriginal()).isZero(); assertThat(savedReturn.getAmountLocal()).isZero();
        assertThat(savedReturn.getReceiptItemId()).isEqualTo(source);
    }

    private static void prepareSnapshots(Fixture fixture, UUID goods, UUID unit, UUID source, UUID currency) {
        when(fixture.units().normalizeAndValidate(any(), any(), any(), anyInt()))
                .thenReturn(new com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy.ResolvedUnit(unit, BigDecimal.ONE));
        when(fixture.em().createNativeQuery(anyString())).thenAnswer(call -> {
            String sql = call.getArgument(0);
            Query query = mock(Query.class, RETURNS_SELF);
            List<Object[]> rows = sql.contains("SELECT DISTINCT h.id")
                    ? List.<Object[]>of(new Object[]{UUID.randomUUID(), currency, BigDecimal.ONE})
                    : sql.contains("FROM purchase_order_items item") || sql.contains("FROM purchase_receipt_items item")
                    ? List.<Object[]>of(new Object[]{source, goods, "SYNTHETIC", "Synthetic goods"})
                    : sql.contains("SELECT goods.id, goods.id")
                    ? List.<Object[]>of(new Object[]{goods, goods, "SYNTHETIC", "Synthetic goods"})
                    : List.of();
            when(query.getResultList()).thenReturn(rows);
            // The DTO reader asks for already-stocked gift base quantity; a new
            // synthetic line has no physical postings yet.
            if (sql.toLowerCase(java.util.Locale.ROOT).contains("select coalesce(sum("))
                when(query.getSingleResult()).thenReturn(BigDecimal.ZERO);
            return query;
        });
    }

    private static void invokeGuard(Class<?> type, Object header, Object item) throws Exception {
        var method = type.getDeclaredMethod("requireNonNegativeStoredCommercial", header.getClass(), List.class);
        method.setAccessible(true);
        try { method.invoke(null, header, List.of(item)); }
        catch (java.lang.reflect.InvocationTargetException exception) {
            if (exception.getCause() instanceof ApiException cause) throw cause;
            throw exception;
        }
    }

    private static void invokeSave(Object service, Object header, Object line) throws Exception {
        var method = service.getClass().getDeclaredMethod("saveItems", header.getClass(), List.class);
        method.setAccessible(true);
        try { method.invoke(service, header, List.of(line)); }
        catch (java.lang.reflect.InvocationTargetException exception) {
            if (exception.getCause() instanceof ApiException cause) throw cause;
            throw exception;
        }
    }

    private static Fixture fixture(Class<?> type) throws Exception {
        var constructor = type.getConstructors()[0];
        var parameters = constructor.getParameterTypes(); Object[] arguments = new Object[parameters.length]; Object items = null;
        EntityManager em = null; com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy units = null;
        for (int index = 0; index < parameters.length; index++) {
            arguments[index] = mock(parameters[index], RETURNS_DEEP_STUBS);
            if (parameters[index].getSimpleName().endsWith("ItemRepository")) items = arguments[index];
            if (parameters[index] == EntityManager.class) em = (EntityManager) arguments[index];
            if (parameters[index] == com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy.class)
                units = (com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy) arguments[index];
        }
        return new Fixture(constructor.newInstance(arguments), items, em, units);
    }

    private record Fixture(Object service, Object items, EntityManager em,
                           com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy units) { }

    @Test
    void persistedGuardsRunBeforeApprovalAndReversalEffects() throws IOException {
        String receipt = read("purchase/receipt/PurchaseReceiptService.java");
        assertBefore(method(receipt, "public ReceiptDetail approve(UUID id)",
                        "public ReceiptDetail reverse(UUID id)"),
                STORED_GUARD_CALL, "normalizePersistedItemUnits(items);");
        assertBefore(method(receipt, "public ReceiptDetail reverse(UUID id)",
                        "private void applyMovement"),
                STORED_GUARD_CALL, "productionSupply.beforePurchaseReceiptReversed(id);");

        String purchaseReturn = read("purchase/ret/PurchaseReturnService.java");
        assertBefore(method(purchaseReturn, "public ReturnDetail approve(UUID id)",
                        "public ReturnDetail reverse(UUID id)"),
                STORED_GUARD_CALL, "normalizePersistedItemUnits(items);");
        assertBefore(method(purchaseReturn, "public ReturnDetail reverse(UUID id)",
                        "private void applyMovement"),
                STORED_GUARD_CALL, "arApService.reverseArAp");

        String salesReturn = read("sales/ret/SalesReturnService.java");
        assertBefore(method(salesReturn, "public ReturnDetail approve(UUID id)",
                        "public ReturnDetail reverse(UUID id)"),
                STORED_GUARD_CALL, "lockStoredSourceGraph(items);");
        assertBefore(method(salesReturn, "public ReturnDetail reverse(UUID id)",
                        "private void applyMovement"),
                STORED_GUARD_CALL, "lockStoredSourceGraph(items);");
    }

    /**
     * ADR-112: 退货请求不再带成本(成本与金额只由服务端派生), 请求阶段只校验数量/单价/折扣;
     * 落库后的成本仍在审核与红冲前校验非负。
     */
    @Test
    void salesReturnGuardsServerDerivedCostOnlyInTheStoredPhase() throws IOException {
        String source = read("sales/ret/SalesReturnService.java");
        String requestGuard = method(source,
                "NonNegativeCommercialSignGuard.requireRequestLine(",
                "SalesReturnItem it = new SalesReturnItem();");
        String storedGuard = method(source,
                "private static void requireNonNegativeStoredCommercial",
                "private void applyTotals");

        assertThat(requestGuard).contains("l.getQty(), l.getPrice(), l.getDiscount()")
                .doesNotContain("getCostAmount");
        assertThat(source).doesNotContain("l.getCostAmount()");
        assertThat(storedGuard).contains("item.getCostAmount()");
    }

    private static void assertWired(String source) {
        assertThat(source)
                .contains("NonNegativeCommercialSignGuard.requireRequestLine(")
                .contains("private static void requireNonNegativeStoredCommercial")
                .contains("NonNegativeCommercialSignGuard.requireStoredTotals(")
                .contains("NonNegativeCommercialSignGuard.requireStoredLine(");
        assertThat(DraftMutationSourceContract.methodNamesInvoking(source, "requireNonNegativeStoredCommercial"))
                .containsExactlyInAnyOrder("approve", "unapprovalEligibility", "reverse");
    }

    private static void assertBefore(String method, String guard, String effect) {
        assertThat(method.indexOf(guard)).isGreaterThanOrEqualTo(0);
        assertThat(method.indexOf(effect)).isGreaterThanOrEqualTo(0);
        assertThat(method.indexOf(guard)).isLessThan(method.indexOf(effect));
    }

    private static String method(String source, String start, String end) {
        int from = source.indexOf(start);
        int to = source.indexOf(end, from + start.length());
        assertThat(from).isGreaterThanOrEqualTo(0);
        assertThat(to).isGreaterThan(from);
        return source.substring(from, to);
    }

    private static int occurrences(String source, String needle) {
        int count = 0;
        int from = 0;
        while ((from = source.indexOf(needle, from)) >= 0) {
            count++;
            from += needle.length();
        }
        return count;
    }

    private static String read(String relativePath) throws IOException {
        return Files.readString(FEATURE_SOURCE.resolve(relativePath), StandardCharsets.UTF_8);
    }
}
