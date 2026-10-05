package com.uten.imp.features.stock.weight.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/**
 * POST /api/stock/weight/params 请求体: 一页表格要用到的行, 最多 500 行 (ADR-135 §7.2, ADR-151 修订)。
 *
 * <p>每行只带结构化身份, 不再要客户端拼字符串 key: 旧契约把 goods|supplier|warehouse|color 拼成最长 147 字的
 * key, 服务端限 100 字, 整批 422 且被页面静默吞掉 (2026-10-04)。响应按请求顺序返回, 客户端按身份对行。
 */
public record WeightParamsRequest(
        @NotNull @Size(max = RequestLimits.DOCUMENT_LINES) List<@Valid @NotNull Line> lines) {

    /**
     * @param goodsId     货品
     * @param supplierId  供应商 (可空; 有该供应商自己的单重时优先用)。单重只按 (货品, 供应商) 解析
     * @param warehouseId 实物仓库 (可空; 提供时另返回该仓库、货品、颜色的库存均重参考)
     * @param colorId     颜色 (可空表示无色, 不表示任意颜色; 只参与库存均重参考)
     */
    public record Line(@NotNull UUID goodsId, UUID supplierId, UUID warehouseId, UUID colorId) {
        public Line(UUID goodsId, UUID supplierId) {
            this(goodsId, supplierId, null, null);
        }
    }
}
