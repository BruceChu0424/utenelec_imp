package com.uten.imp.features.master.goods;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;

import java.util.Objects;
import java.util.UUID;

/** Fast API guard; V498 independently enforces the same rule under row locking. */
final class GoodsQuantityUnitPolicy {
    private GoodsQuantityUnitPolicy() {}

    static void requireUnchangedIfUsed(Goods goods, GoodsSaveRequest request) {
        if (!goods.isQuantityUnitLocked() || !request.hasUnitReference()) return;
        UUID current = goods.getUnit() == null ? null : goods.getUnit().getId();
        if (Objects.equals(current, request.getUnitId())
                && (current != null || Objects.equals(goods.getUnitLegacyId(), request.getUnitLegacyId()))) return;
        throw new ApiException(ErrorCode.CONFLICT, current == null
                ? "该货品已有数量记录，但历史基本单位尚未核对，不能在普通编辑中补选或改写单位。请先由管理员按原始单据受控核对。"
                : "该货品已有数量记录或组装引用，基本单位不能再改。请保留原单位；不同计量规格请新建货品。");
    }
}
