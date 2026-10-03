package com.uten.imp.features.production.fulfillment;

import com.uten.imp.application.port.WorkshopMaterialStatePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

/** A workshop material decision must precede either ordinary picking entry. */
public final class ProductionOrderMaterialGate {
    private ProductionOrderMaterialGate() {}

    public static String unresolvedSql(String segmentExpression) {
        return "fn_segment_bin_material_state(" + segmentExpression + ") IN ('"
                + WorkshopMaterialStatePort.NEED_CHOICE + "','" + WorkshopMaterialStatePort.NEED_BIN + "')";
    }

    public static void requireResolved(String state) {
        if (WorkshopMaterialStatePort.NEED_CHOICE.equals(state)) {
            throw new ApiException(ErrorCode.CONFLICT, "请先在开工确认表里认料，再办理需要按工单领用的材料");
        }
        if (WorkshopMaterialStatePort.NEED_BIN.equals(state)) {
            throw new ApiException(ErrorCode.CONFLICT, "这个产品使用车间内料仓的料，请先开启本车间整批领料");
        }
    }
}
