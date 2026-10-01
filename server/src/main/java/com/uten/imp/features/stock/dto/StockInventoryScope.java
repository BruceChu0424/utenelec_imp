package com.uten.imp.features.stock.dto;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.util.UUID;

/** Read-side scope only: no business state or quantity is changed by these options. */
public record StockInventoryScope(UUID warehouseId, UUID colorId, boolean colorNull,
                                  boolean inventoryOnly, boolean includeDefective, boolean includeLineSide) {
    public StockInventoryScope {
        if (colorId != null && colorNull) {
            throw new ApiException(ErrorCode.MALFORMED_REQUEST, "colorId 与 colorNull 不能同时指定");
        }
    }

    public String getWarehouseMode() {
        return inventoryOnly ? "INSTANT_INVENTORY" : "ALL_WAREHOUSES";
    }

    /** Plans remain global and color-specific; warehouse filtering never turns them into inventory. */
    public String getProductionPlanScope() { return "GLOBAL_GOODS_COLOR"; }
}
