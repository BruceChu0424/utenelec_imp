package com.uten.imp.features.master.reference;

import com.uten.imp.features.master.goods.dto.GoodsListItem;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;

/** Whitelisted physical identity and quantity rules; prices, discount and stock totals are not references. */
public final class GoodsReferenceProjection {
    private GoodsReferenceProjection() { }
    private static final Set<String> QUERY_FIELDS = Set.of("id", "code", "name", "nameEn", "model", "spec",
            "status", "legacyId", "series", "material", "colorId", "unitId", "colorLegacyId", "unitLegacyId",
            "colorName", "unitName", "sourceType", "categoryId", "autoCreated", "stockPlace", "minOrderQty",
            "orderMultipleQty", "owningWarehouse", "owningWarehouseId", "owningWarehouseName", "owningWorkshop",
            "owningWorkshopId", "owningWorkshopName", "issueMethod", "periodicCostBasis", "bulkPackageQty",
            "recycledMaterial", "mouldCode", "mouldName", "rearInsertCode", "cNumber", "color", "unit", "mould", "colorRef", "unitRef");

    public static void validateField(String field) {
        if (!QUERY_FIELDS.contains(field)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "选择货品不提供此字段的筛选信息");
        }
    }

    public static com.uten.imp.features.master.goods.dto.GoodsFacets facets(
            com.uten.imp.features.master.goods.dto.GoodsFacets source) {
        Map<String,Long> counts = new LinkedHashMap<>();
        source.getNullCounts().forEach((key, value) -> {
            if (QUERY_FIELDS.contains(key)) counts.put(key, value);
        });
        return new com.uten.imp.features.master.goods.dto.GoodsFacets(source.getCode(), source.getSeries(),
                source.getModel(), source.getName(), source.getSpec(), source.getMaterial(), source.getRearInsertCode(),
                java.util.List.of(), source.getColorLegacyId(), source.getUnitLegacyId(), source.getSourceType(),
                source.getOwningWarehouse(), source.getOwningWorkshop(), counts, source.getColorRef(), source.getUnitRef());
    }

    public static void validateQuery(GoodsQueryFilter filter, String sort) {
        if (sort != null && !sort.isBlank() && !QUERY_FIELDS.contains(sort)
                || filter.columnSearch() != null && !QUERY_FIELDS.containsAll(filter.columnSearch().keySet())
                || filter.nullFields() != null && !QUERY_FIELDS.containsAll(filter.nullFields())
                || filter.paper() != null || filter.requireRemark() != null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "选择货品只能按当前业务可见的引用字段筛选或排序");
        }
    }
    public static Map<String,Object> of(GoodsListItem item) {
        Map<String,Object> row = new LinkedHashMap<>();
        row.put("id", item.getId());
        row.put("code", item.getCode());
        row.put("name", item.getName());
        row.put("nameEn", item.getNameEn());
        row.put("model", item.getModel());
        row.put("spec", item.getSpec());
        row.put("status", item.getStatus());
        row.put("legacyId", item.getLegacyId());
        row.put("series", item.getSeries());
        row.put("material", item.getMaterial());
        row.put("mouldCode", item.getMouldCode());
        row.put("mouldName", item.getMouldName());
        row.put("rearInsertCode", item.getRearInsertCode());
        row.put("cNumber", item.getCNumber());
        row.put("colorId", item.getColorId());
        row.put("unitId", item.getUnitId());
        row.put("colorLegacyId", item.getColorLegacyId());
        row.put("unitLegacyId", item.getUnitLegacyId());
        row.put("colorName", item.getColorName());
        row.put("unitName", item.getUnitName());
        row.put("sourceType", item.getSourceType());
        row.put("categoryId", item.getCategoryId());
        row.put("autoCreated", item.isAutoCreated());
        row.put("stockPlace", item.getStockPlace());
        row.put("minOrderQty", item.getMinOrderQty());
        row.put("orderMultipleQty", item.getOrderMultipleQty());
        row.put("owningWarehouseId", item.getOwningWarehouseId());
        row.put("owningWarehouseName", item.getOwningWarehouseName());
        row.put("owningWorkshopId", item.getOwningWorkshopId());
        row.put("owningWorkshopName", item.getOwningWorkshopName());
        row.put("issueMethod", item.getIssueMethod());
        row.put("periodicCostBasis", item.getPeriodicCostBasis());
        row.put("bulkPackageQty", item.getBulkPackageQty());
        row.put("recycledMaterial", item.isRecycledMaterial());
        row.put("searchRank", item.getSearchRank());
        row.put("searchMatchKind", item.getSearchMatchKind());
        row.put("hasBom", item.isHasBom());
        row.put("writable", false);
        return row;
    }
}
