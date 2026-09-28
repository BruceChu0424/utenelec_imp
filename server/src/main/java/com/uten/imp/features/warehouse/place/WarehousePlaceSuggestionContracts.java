package com.uten.imp.features.warehouse.place;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/**
 * 入库建议库位的 HTTP 契约：采购/委外到货登记与产成品到货登记共用同一个入口。
 *
 * <p>建议链：本仓×货品×颜色的记忆库位(warehouse_goods_place_preferences) →
 * 货品主档 stock_place → 无。只读主档关系，不扫描任何登记/入库历史单据。</p>
 */
public final class WarehousePlaceSuggestionContracts {

    /** 一次最多问多少个(货品, 颜色)：与单据行上限同口径。 */
    public static final int MAX_ITEMS = RequestLimits.DOCUMENT_LINES;

    private WarehousePlaceSuggestionContracts() {
    }

    public record PlaceSuggestionRequest(
            @NotNull UUID warehouseId,
            @Valid
            @NotNull
            @Size(min = 1, max = MAX_ITEMS,
                    message = "库位建议一次需提供 1 至 500 个货品")
            List<@NotNull @Valid PlaceSuggestionItemRequest> items) {
    }

    /** colorId 可空：无颜色货品按「颜色为空」这一维度匹配记忆库位。 */
    public record PlaceSuggestionItemRequest(
            @NotNull UUID goodsId,
            UUID colorId) {
    }

    /** 按请求顺序、每个不同的(goodsId, colorId)恰好一条。 */
    public record PlaceSuggestionsView(List<PlaceSuggestionView> items) {

        public PlaceSuggestionsView {
            items = List.copyOf(items);
        }
    }

    /**
     * source：WAREHOUSE_PREFERENCE = 本仓记忆库位；GOODS_MASTER = 货品主档库位；
     * NONE = 无建议(含货品不存在/已删除)，此时 place 为 null。
     */
    public record PlaceSuggestionView(
            UUID goodsId,
            UUID colorId,
            String place,
            String source) {
    }
}
