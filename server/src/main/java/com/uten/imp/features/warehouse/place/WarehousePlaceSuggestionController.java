package com.uten.imp.features.warehouse.place;

import com.uten.imp.features.warehouse.place.WarehousePlaceSuggestionContracts.PlaceSuggestionRequest;
import com.uten.imp.features.warehouse.place.WarehousePlaceSuggestionContracts.PlaceSuggestionsView;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 入库建议库位(只读)：采购/委外到货登记与产成品到货登记用同一个入口按
 * 仓库 + (货品, 颜色) 取建议。用 POST 仅为承载最多 500 个维度的请求体，不写任何数据。
 */
@RestController
@RequestMapping("/api/warehouse/place-suggestions")
@RequiredArgsConstructor
public class WarehousePlaceSuggestionController {

    private final WarehousePlaceSuggestionService service;

    @PostMapping
    @PreAuthorize("hasAuthority('warehouse_inbound:view') or hasAuthority('stock_doc:view')")
    public PlaceSuggestionsView suggest(
            @Valid @RequestBody PlaceSuggestionRequest request) {
        return service.suggest(request);
    }
}
