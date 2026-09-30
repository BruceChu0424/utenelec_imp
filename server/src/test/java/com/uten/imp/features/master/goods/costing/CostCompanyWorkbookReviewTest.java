package com.uten.imp.features.master.goods.costing;

import com.uten.imp.common.storage.ImmutableDocumentStore;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

/** Optional local acceptance against the user-supplied workbook; no company file is checked into Git. */
@EnabledIfSystemProperty(named="uten.cost.companyWorkbook", matches=".+")
class CostCompanyWorkbookReviewTest {
    @Test void preservesFortyDetailBlocksIncludingProductsAbsentFromTheThirtySevenRowSummary() throws Exception {
        Path path = Path.of(System.getProperty("uten.cost.companyWorkbook"));
        byte[] bytes = Files.readAllBytes(path);
        var preview = GoodsCostWorkbookParser.parse(UUID.randomUUID(), path.getFileName().toString(), ImmutableDocumentStore.digest(bytes), bytes);
        assertThat(preview.blocks()).hasSize(40);
        assertThat(preview.blocks()).extracting(GoodsCostImportContracts.Block::label)
                .contains("80N德式插带双USB", "哈萨克五80B双电脑", "哈萨克五80B三联单控开关");
        assertThat(preview.blocks().getFirst().label()).contains("80N");
        assertThat(preview.warnings()).anyMatch(warning -> warning.contains("55") && warning.contains("外部引用"));
        assertThat(preview.blocks().getFirst().rows()).anyMatch(row -> row.name().contains("铁耳") && "2".equals(row.quantity()));
        assertThat(preview.blocks().stream().flatMap(block -> block.rows().stream()).allMatch(GoodsCostImportContracts.ImportRow::requiresReview)).isTrue();
    }
}
