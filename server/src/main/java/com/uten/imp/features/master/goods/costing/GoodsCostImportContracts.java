package com.uten.imp.features.master.goods.costing;

import java.util.List;
import java.util.UUID;
import static com.uten.imp.features.master.goods.costing.GoodsCostContracts.*;

public final class GoodsCostImportContracts {
    private GoodsCostImportContracts() {}
    public record ImportRow(String key, int rowNumber, String name, String code, String unit,
            String quantity, String unitPrice, String amount, String formula,
            boolean externalReference, boolean requiresReview) {}
    public record Block(String key, String label, String sheetName, List<ImportRow> rows) {}
    public record Preview(UUID id, String sourceName, String sha256, List<Block> blocks, List<String> warnings) {}
    /** Every source row is explicitly mapped or skipped; quantities are opt-in to avoid changing BOM semantics. */
    public record Mapping(String rowKey, String kind, String targetPath, String adoptedQty,
            String unitPrice, String priceUnitRate, String feeName, String skipReason, boolean reviewed) {}
    public record Apply(UUID importId, String blockKey, DraftInput input, List<Mapping> mappings) {}
    public record Applied(DraftInput input, Calculation calculation, List<String> warnings) {}
}
