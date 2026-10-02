package com.uten.imp.features.stock.weight;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.stock.weight.dto.BalanceWeightView;
import com.uten.imp.features.stock.weight.dto.GoodsWeightView;
import com.uten.imp.features.stock.weight.dto.SetBalanceWeightRequest;
import com.uten.imp.features.stock.weight.dto.WeightExcludeRequest;
import com.uten.imp.features.stock.weight.dto.WeightObservationRow;
import com.uten.imp.features.stock.weight.dto.WeightParamsRequest;
import com.uten.imp.features.stock.weight.dto.WeightParamsResponse;
import com.uten.imp.features.stock.weight.dto.WeightProfileUpdateRequest;
import com.uten.imp.features.stock.weight.dto.WeightSampleRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/**
 * 仓库重量与单重学习 API (ADR-135 §3.5 / §7.2)。
 *
 * <ul>
 *   <li>POST /api/stock/weight/params: 一页表格的单重参数 (stock:view, 最多 500 行);</li>
 *   <li>GET  /goods/{goodsId}: 货品单重学习概况; GET /goods/{goodsId}/observations: 称重记录 (stock:view);</li>
 *   <li>POST /goods/{goodsId}/samples: 称样校准 (到货入库 / 仓库单据编辑 / 称重管理 任一权限);</li>
 *   <li>PUT /goods/{goodsId}/profile、POST /observations/{observationId}/exclude|include、
 *       POST /goods/{goodsId}/reset-regime、POST /balances/set (核重): stock:weight:manage。</li>
 * </ul>
 * 供应商/往来方名称只对 stock_report:view 或 stock:weight:manage 显示。
 */
@RestController
@RequestMapping("/api/stock/weight")
@RequiredArgsConstructor
public class StockWeightController {

    private final GoodsWeightEstimateService estimates;
    private final GoodsWeightProfileService profiles;
    private final StockWeightAdjustmentService adjustments;
    private final SecurityContextCurrentUser currentUser;

    @PostMapping("/params")
    @PreAuthorize("hasAuthority('stock:view')")
    public WeightParamsResponse params(@Valid @RequestBody WeightParamsRequest request) {
        return new WeightParamsResponse(estimates.params(request.lines()));
    }

    @GetMapping("/goods/{goodsId}")
    @PreAuthorize("hasAuthority('stock:view')")
    public GoodsWeightView goods(@PathVariable UUID goodsId) {
        return estimates.goodsView(goodsId);
    }

    @GetMapping("/goods/{goodsId}/observations")
    @PreAuthorize("hasAuthority('stock:view')")
    public PageResponse<WeightObservationRow> observations(
            @PathVariable UUID goodsId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String kind,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) String stage) {
        return estimates.observations(goodsId, page, size, kind, supplierId, stage);
    }

    @PostMapping("/goods/{goodsId}/samples")
    @PreAuthorize("hasAnyAuthority('warehouse_inbound:stock_in', 'stock_doc:edit', 'stock:weight:manage')")
    public GoodsWeightView sample(@PathVariable UUID goodsId, @Valid @RequestBody WeightSampleRequest request) {
        return profiles.recordSample(goodsId, request);
    }

    @PutMapping("/goods/{goodsId}/profile")
    @PreAuthorize("hasAuthority('stock:weight:manage')")
    public GoodsWeightView updateProfile(@PathVariable UUID goodsId,
                                         @Valid @RequestBody WeightProfileUpdateRequest request) {
        return profiles.updateProfile(goodsId, request);
    }

    @PostMapping("/observations/{observationId}/exclude")
    @PreAuthorize("hasAuthority('stock:weight:manage')")
    public GoodsWeightView exclude(@PathVariable UUID observationId,
                                   @Valid @RequestBody(required = false) WeightExcludeRequest request) {
        return profiles.exclude(observationId, request == null ? null : request.reason());
    }

    @PostMapping("/observations/{observationId}/include")
    @PreAuthorize("hasAuthority('stock:weight:manage')")
    public GoodsWeightView include(@PathVariable UUID observationId) {
        return profiles.include(observationId);
    }

    @PostMapping("/goods/{goodsId}/reset-regime")
    @PreAuthorize("hasAuthority('stock:weight:manage')")
    public GoodsWeightView resetRegime(@PathVariable UUID goodsId) {
        return profiles.resetRegime(goodsId);
    }

    /** 旧快捷核重入口退役，保留明确指引；库存目标重量须送盘点审核。 */
    @PostMapping("/balances/set")
    @PreAuthorize("hasAuthority('stock:weight:manage')")
    public BalanceWeightView setBalanceWeight(@Valid @RequestBody SetBalanceWeightRequest request) {
        throw new ApiException(ErrorCode.CONFLICT, "库存核重已改为盘点审批，请通过盘点模式录入目标重量并提交审核");
    }
}
