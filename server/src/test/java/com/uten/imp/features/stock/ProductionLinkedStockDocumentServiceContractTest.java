package com.uten.imp.features.stock;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertTrue;

class ProductionLinkedStockDocumentServiceContractTest {

    @Test
    void genericUpdateAndDeleteRejectProductionOwnedDocuments()
            throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/stock/StockDocService.java"));

        int update = source.indexOf(
                "public StockDocDetail update(UUID id");
        int delete = source.indexOf("public void delete(UUID id)");
        int approve = source.indexOf("public StockDocDetail approve(UUID id)");

        assertTrue(update >= 0 && delete > update && approve > delete);
        assertTrue(source.substring(update, delete).contains(
                "rejectGenericMutationOfProductionDocument(d)"));
        assertTrue(source.substring(delete, approve).contains(
                "rejectGenericMutationOfProductionDocument(d)"));
        assertTrue(source.contains("ErrorCode.CONFLICT"));
        assertTrue(source.contains("fn_is_production_linked_stock_document"));
        assertTrue(source.contains("productionLinked, canEdit, canDelete"));
    }
}
