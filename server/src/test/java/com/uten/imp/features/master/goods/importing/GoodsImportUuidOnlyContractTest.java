package com.uten.imp.features.master.goods.importing;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Locks both the JSON request boundary and importer implementation to UUID-only relationships. */
class GoodsImportUuidOnlyContractTest {

    @Test
    void importedGoodsSaveRequestUsesOnlyUuidRelationshipSettersAndNoFindFirst() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/master/goods/importing/GoodsImportService.java"));

        assertFalse(source.contains("setColorLegacyId("));
        assertFalse(source.contains("setUnitLegacyId("));
        assertFalse(source.contains("findFirstByNameIgnoreCaseAndDeletedFalse"));
        assertTrue(source.contains("req.setColorId("));
        assertTrue(source.contains("req.setUnitId("));
    }
}
