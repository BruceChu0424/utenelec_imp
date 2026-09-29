package com.uten.imp.features.stock.weight.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/** POST /api/stock/weight/params 请求体: 一页表格要用到的货品 (可带供应商), 最多 500 行。 */
public record WeightParamsRequest(
        @NotNull @Size(max = RequestLimits.DOCUMENT_LINES) List<@Valid @NotNull Line> lines) {

    /**
     * @param key        客户端行 key (原样返回, 用于对上表格行)
     * @param goodsId    货品
     * @param supplierId 供应商 (可空; 有该供应商自己的单重时优先用)
     */
    public record Line(@NotBlank @Size(max = 100) String key, @NotNull UUID goodsId, UUID supplierId) {
    }
}
