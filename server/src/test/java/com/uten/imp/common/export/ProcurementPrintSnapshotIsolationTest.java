package com.uten.imp.common.export;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.purchase.order.PurchasePrintAuthorizationController;
import com.uten.imp.features.subcontract.order.SubcontractPrintAuthorizationController;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ProcurementPrintSnapshotIsolationTest {
    @Test void renderedFactsAndDigestCannotChangeThroughTheInputOrReturnedLines() throws Exception {
        var line = new ProcurementOrderPrintDocument.PrintLine(null, 1, "SKU", "货品", null, null,
                null, "件", "2", "2", null, null, null, null);
        var requested = new ArrayList<>(List.of(line));
        var document = document(requested);
        String digest = document.contentDigest();
        var mapper = new ObjectMapper();
        var wire = mapper.valueToTree(document);
        requested.clear();
        assertEquals(List.of(line), document.lines());
        assertEquals(digest, document.contentDigest());
        assertEquals(wire, mapper.valueToTree(document));
        assertThrows(UnsupportedOperationException.class, () -> document.lines().clear());
        assertThrows(UnsupportedOperationException.class, () -> document.lines().set(0, line));
        assertThrows(UnsupportedOperationException.class, () -> document.lines().subList(0, 1).clear());
        assertEquals(wire, mapper.valueToTree(mapper.treeToValue(wire, ProcurementOrderPrintDocument.class)));
    }

    @Test void nullableAndEmptyPrintFactsKeepTheirWireMeaning() throws Exception {
        var mapper = new ObjectMapper();
        assertNull(document(null).lines());
        assertEquals(List.of(), document(new ArrayList<>()).lines());
        var malformed = document(new ArrayList<>(Arrays.asList((ProcurementOrderPrintDocument.PrintLine) null)));
        assertEquals(1, malformed.lines().size());
        assertNull(malformed.lines().getFirst());
        assertTrue(mapper.valueToTree(document(null)).get("lines").isNull());
        assertEquals(0, mapper.valueToTree(document(List.of())).get("lines").size());
    }

    @Test void sqlHeaderMapAndEveryRowAreIndependentSnapshotsInBothDirections() {
        UUID first = UUID.randomUUID(), second = UUID.randomUUID();
        Object[] header = {"原供应商", "电话"};
        Object[] row = {first, "原编号"};
        Map<UUID,Object[]> requested = new LinkedHashMap<>();
        requested.put(first, row);
        requested.put(second, null);
        var facts = new ProcurementOrderPrintSupport.Facts(header, requested, "公司", "审核人");
        header[0] = "被外部替换";
        row[1] = "被外部替换";
        requested.clear();
        assertEquals("原供应商", facts.header()[0]);
        assertEquals(List.of(first, second), new ArrayList<>(facts.lines().keySet()));
        assertNull(facts.lines().get(second));
        assertEquals("原编号", facts.lines().get(first)[1]);
        facts.header()[0] = "通过返回头修改";
        facts.lines().get(first)[1] = "通过返回行修改";
        ProcurementOrderPrintSupport.line(facts, first)[1] = "通过共用选行入口修改";
        assertEquals("原供应商", facts.header()[0]);
        assertEquals("原编号", ProcurementOrderPrintSupport.line(facts, first)[1]);
        assertThrows(UnsupportedOperationException.class, () -> facts.lines().clear());
        var malformed = new ProcurementOrderPrintSupport.Facts(null, null, null, null);
        assertNull(malformed.header());
        assertNull(malformed.lines());
    }

    @Test void printAuthorizationRequestsFreezeSelectionsWithoutChangingValidation() throws Exception {
        var purchaseProof = new PurchasePrintAuthorizationController.DocumentProof(UUID.randomUUID(), "a".repeat(64));
        var purchaseInputs = new ArrayList<>(List.of(purchaseProof));
        var purchase = new PurchasePrintAuthorizationController.Request(purchaseInputs);
        purchaseInputs.clear();
        assertEquals(List.of(purchaseProof), purchase.documents());
        assertThrows(UnsupportedOperationException.class, () -> purchase.documents().clear());
        var subcontractProof = new SubcontractPrintAuthorizationController.DocumentProof(UUID.randomUUID(), "b".repeat(64));
        var subcontractInputs = new ArrayList<>(List.of(subcontractProof));
        var subcontract = new SubcontractPrintAuthorizationController.Request(subcontractInputs);
        subcontractInputs.clear();
        assertEquals(List.of(subcontractProof), subcontract.documents());
        assertThrows(UnsupportedOperationException.class, () -> subcontract.documents().clear());
        var mapper = new ObjectMapper();
        assertEquals(mapper.valueToTree(purchase), mapper.valueToTree(mapper.treeToValue(
                mapper.valueToTree(purchase), PurchasePrintAuthorizationController.Request.class)));
        assertEquals(mapper.valueToTree(subcontract), mapper.valueToTree(mapper.treeToValue(
                mapper.valueToTree(subcontract), SubcontractPrintAuthorizationController.Request.class)));
        try (var factory = jakarta.validation.Validation.buildDefaultValidatorFactory()) {
            var validator = factory.getValidator();
            assertTrue(validator.validate(purchase).isEmpty());
            assertTrue(validator.validate(subcontract).isEmpty());
            for (String json : List.of("{}", "{\"documents\":null}", "{\"documents\":[]}", "{\"documents\":[null]}")) {
                assertFalse(validator.validate(mapper.readValue(json, PurchasePrintAuthorizationController.Request.class)).isEmpty());
                assertFalse(validator.validate(mapper.readValue(json, SubcontractPrintAuthorizationController.Request.class)).isEmpty());
            }
        }
    }

    @Test void explicitRequestValuesKeepRecordEqualityAndEveryValidationBoundary() throws Exception {
        var proof = new PurchasePrintAuthorizationController.DocumentProof(UUID.randomUUID(), "a".repeat(64));
        var current = new PurchasePrintAuthorizationController.Request(List.of(proof));
        var same = new PurchasePrintAuthorizationController.Request(List.of(proof));
        var reference = new PreviousRequest<>(List.of(proof));
        assertEquals(current, same);
        assertEquals(reference.hashCode(), current.hashCode());
        assertEquals(reference.toString().replaceFirst("PreviousRequest", "Request"), current.toString());
        assertNotEquals(current, new PurchasePrintAuthorizationController.Request(List.of()));
        assertNotEquals(current, reference);
        var subcontractProof = new SubcontractPrintAuthorizationController.DocumentProof(proof.id(), proof.contentDigest());
        var subcontract = new SubcontractPrintAuthorizationController.Request(List.of(subcontractProof));
        assertEquals(subcontract, new SubcontractPrintAuthorizationController.Request(List.of(subcontractProof)));
        assertEquals(new PreviousRequest<>(List.of(subcontractProof)).hashCode(), subcontract.hashCode());
        assertEquals(new PreviousRequest<>(List.of(subcontractProof)).toString().replaceFirst("PreviousRequest", "Request"), subcontract.toString());
        try (var factory = jakarta.validation.Validation.buildDefaultValidatorFactory()) {
            var validator = factory.getValidator();
            for (List<?> documents : Arrays.<List<?>>asList(null, List.of(), Arrays.asList((Object) null))) {
                @SuppressWarnings("unchecked")
                var purchase = new PurchasePrintAuthorizationController.Request(
                        (List<PurchasePrintAuthorizationController.DocumentProof>) documents);
                @SuppressWarnings("unchecked")
                var sub = new SubcontractPrintAuthorizationController.Request(
                        (List<SubcontractPrintAuthorizationController.DocumentProof>) documents);
                var previous = new PreviousRequest<>(documents);
                var expected = violationPaths(validator.validate(previous));
                assertEquals(expected, violationPaths(validator.validate(purchase)));
                assertEquals(expected, violationPaths(validator.validate(sub)));
                var referenceAccessor = PreviousRequest.class.getDeclaredMethod("documents");
                var expectedReturn = violationPaths(validator.forExecutables().validateReturnValue(
                        previous, referenceAccessor, documents));
                assertEquals(expectedReturn, violationPaths(validator.forExecutables().validateReturnValue(
                        purchase, PurchasePrintAuthorizationController.Request.class.getMethod("documents"), purchase.documents())));
                assertEquals(expectedReturn, violationPaths(validator.forExecutables().validateReturnValue(
                        sub, SubcontractPrintAuthorizationController.Request.class.getMethod("documents"), sub.documents())));
                var referenceConstructor = PreviousRequest.class.getDeclaredConstructor(List.class);
                var expectedConstructor = violationPaths(validator.forExecutables().validateConstructorParameters(
                        referenceConstructor, new Object[]{documents}));
                assertEquals(expectedConstructor, violationPaths(validator.forExecutables().validateConstructorParameters(
                        PurchasePrintAuthorizationController.Request.class.getConstructor(List.class), new Object[]{documents})));
                assertEquals(expectedConstructor, violationPaths(validator.forExecutables().validateConstructorParameters(
                        SubcontractPrintAuthorizationController.Request.class.getConstructor(List.class), new Object[]{documents})));
            }
        }
        var mapper = new ObjectMapper();
        var facts = new ProcurementOrderPrintSupport.Facts(new Object[]{"供应商"}, Map.of(), "公司", "审核人");
        var wire = mapper.valueToTree(facts);
        assertEquals(List.of("header", "lines", "companyName", "reviewerName"),
                java.util.stream.StreamSupport.stream(java.util.Spliterators.spliteratorUnknownSize(
                        wire.fieldNames(), 0), false).toList());
        assertEquals(wire, mapper.valueToTree(mapper.treeToValue(wire, ProcurementOrderPrintSupport.Facts.class)));
    }

    private record PreviousRequest<T>(@jakarta.validation.constraints.NotEmpty
            @jakarta.validation.constraints.Size(max=100)
            List<@jakarta.validation.constraints.NotNull @jakarta.validation.Valid T> documents) { }

    private static java.util.Set<String> violationPaths(java.util.Set<? extends jakarta.validation.ConstraintViolation<?>> errors) {
        return errors.stream().map(error -> error.getPropertyPath().toString()
                        .replaceFirst("^(?:PreviousRequest|Request)\\.", "")
                        + ":" + error.getConstraintDescriptor().getAnnotation().annotationType().getSimpleName())
                .collect(java.util.stream.Collectors.toSet());
    }

    private static ProcurementOrderPrintDocument document(List<ProcurementOrderPrintDocument.PrintLine> lines) {
        return new ProcurementOrderPrintDocument(UUID.fromString("3e6ca1be-2533-4fd2-9daa-700000000001"), "PO-1",
                null, null, "公司", "电话", "供应商", "联系人", "联系电话", "送货地址", "人民币", "CNY", "月结",
                "2.00", false, "备注", "制单人", "审核人", "草稿", lines, false, "PURCHASE");
    }
}
