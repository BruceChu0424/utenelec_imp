package com.uten.imp.features.warehouse.place;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.place.WarehousePlaceSuggestionContracts.PlaceSuggestionItemRequest;
import com.uten.imp.features.warehouse.place.WarehousePlaceSuggestionContracts.PlaceSuggestionRequest;
import com.uten.imp.features.warehouse.place.WarehousePlaceSuggestionContracts.PlaceSuggestionView;
import com.uten.imp.features.warehouse.place.WarehousePlaceSuggestionContracts.PlaceSuggestionsView;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Objects;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 入库建议库位(采购/委外到货登记 + 产成品到货登记共用)。
 *
 * <p>口径与记忆写入端一致：本仓×货品×颜色(颜色 IS NOT DISTINCT FROM)的
 * {@code warehouse_goods_place_preferences.place} → 货品主档 {@code goods.stock_place}
 * (去空白后非空) → 无。一次有界查询，只读主档关系，不扫描登记/入库历史单据；
 * 货品不存在或已删除时返回 NONE 而不报错(建议只是预填，不能挡住登记)。</p>
 */
@Service
@RequiredArgsConstructor
public class WarehousePlaceSuggestionService {

    public static final String SOURCE_WAREHOUSE_PREFERENCE = "WAREHOUSE_PREFERENCE";
    public static final String SOURCE_GOODS_MASTER = "GOODS_MASTER";
    public static final String SOURCE_NONE = "NONE";

    /**
     * 请求维度以两条平行数组展开(WITH ORDINALITY 保序)；颜色数组里空串=NULL
     * (string_to_array 第三参)，全仓库既有写法，避免 Hibernate 可空单参的类型推断坑。
     * 仓库资格作为无列引用的过滤条件：不合格时整体零行，由调用方转成校验错误。
     */
    static final String SUGGESTION_SQL = """
            SELECT requested.position,
                   requested.goods_id,
                   CASE
                       WHEN goods.id IS NULL THEN NULL
                       WHEN preference.id IS NOT NULL THEN preference.place
                       ELSE NULLIF(BTRIM(goods.stock_place), '')
                   END AS suggested_place,
                   CASE
                       WHEN goods.id IS NULL THEN 'NONE'
                       WHEN preference.id IS NOT NULL THEN 'WAREHOUSE_PREFERENCE'
                       WHEN NULLIF(BTRIM(goods.stock_place), '') IS NOT NULL
                           THEN 'GOODS_MASTER'
                       ELSE 'NONE'
                   END AS suggestion_source
            FROM unnest(
                     CAST(string_to_array(:goodsIds, ',') AS uuid[]),
                     CAST(string_to_array(:colorIds, ',', '') AS uuid[]))
                 WITH ORDINALITY AS requested(goods_id, color_id, position)
            LEFT JOIN goods goods
              ON goods.id = requested.goods_id
             AND goods.is_deleted = FALSE
            LEFT JOIN warehouse_goods_place_preferences preference
              ON preference.warehouse_id = CAST(:warehouseId AS uuid)
             AND preference.goods_id = requested.goods_id
             AND preference.color_id IS NOT DISTINCT FROM requested.color_id
            WHERE fn_warehouse_is_active_accounting_leaf(CAST(:warehouseId AS uuid))
            ORDER BY requested.position
            """;

    private final EntityManager em;

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('warehouse_inbound:view') or hasAuthority('stock_doc:view')")
    public PlaceSuggestionsView suggest(PlaceSuggestionRequest request) {
        List<Dimension> dimensions = normalize(request);
        String goodsIds = dimensions.stream()
                .map(dimension -> dimension.goodsId().toString())
                .collect(Collectors.joining(","));
        String colorIds = dimensions.stream()
                .map(dimension -> Objects.toString(dimension.colorId(), ""))
                .collect(Collectors.joining(","));
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery(SUGGESTION_SQL)
                        .setParameter("warehouseId", request.warehouseId())
                        .setParameter("goodsIds", goodsIds)
                        .setParameter("colorIds", colorIds));
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "所选仓库不可用，请重新选择");
        }
        if (rows.size() != dimensions.size()) {
            throw new IllegalStateException("库位建议行数与请求维度不一致");
        }
        List<PlaceSuggestionView> items = new ArrayList<>(dimensions.size());
        for (int index = 0; index < rows.size(); index++) {
            Object[] row = rows.get(index);
            Dimension dimension = dimensions.get(index);
            if (((Number) row[0]).intValue() != index + 1
                    || !dimension.goodsId().equals(row[1])) {
                throw new IllegalStateException("库位建议行顺序与请求维度不一致");
            }
            items.add(new PlaceSuggestionView(
                    dimension.goodsId(), dimension.colorId(),
                    row[2] == null ? null : row[2].toString(),
                    row[3] == null ? SOURCE_NONE : row[3].toString()));
        }
        return new PlaceSuggestionsView(items);
    }

    /** 校验并按首次出现顺序去重；控制器 @Valid 已拦一遍，这里兜底直调。 */
    static List<Dimension> normalize(PlaceSuggestionRequest request) {
        if (request == null || request.warehouseId() == null) {
            throw validation("库位建议缺少仓库");
        }
        if (request.items() == null || request.items().isEmpty()) {
            throw validation("库位建议缺少货品");
        }
        if (request.items().size() > WarehousePlaceSuggestionContracts.MAX_ITEMS) {
            throw validation("库位建议一次最多 "
                    + WarehousePlaceSuggestionContracts.MAX_ITEMS + " 个货品");
        }
        LinkedHashSet<Dimension> distinct = new LinkedHashSet<>();
        for (PlaceSuggestionItemRequest item : request.items()) {
            if (item == null || item.goodsId() == null) {
                throw validation("库位建议的货品不能为空");
            }
            distinct.add(new Dimension(item.goodsId(), item.colorId()));
        }
        return List.copyOf(distinct);
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    record Dimension(UUID goodsId, UUID colorId) {
    }
}
