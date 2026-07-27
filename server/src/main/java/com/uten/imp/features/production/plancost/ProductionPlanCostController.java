package com.uten.imp.features.production.plancost;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.production.plancost.dto.PlanCostAggregation;
import com.uten.imp.features.production.plancost.dto.PlanCostQueryFilter;
import com.uten.imp.features.production.plancost.dto.PlanCostRow;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.format.annotation.DateTimeFormat.ISO;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 生产计划成本 / BOM 展开 API（生产管理 · <b>只读</b>）。
 *
 * <p>本期"保数据完整 + 只读查询"（design §3.5/§4.2）：
 * <ul>
 *   <li>GET /api/production/plan-costs             分页查询（planItemId/masterGoodsId/goodsId/parentId/...）</li>
 *   <li>GET /api/production/plan-costs/{id}        单行详情</li>
 *   <li>GET /api/production/plan-costs/aggregate   按顶层成品汇总（design §6.2）</li>
 * </ul>
 *
 * <p>无 POST/PUT/DELETE（BOM 展开 1.36M 行本期不编辑，design §3.5）。
 */
@RestController
@RequestMapping("/api/production/plan-costs")
@RequiredArgsConstructor
public class ProductionPlanCostController {

    private final ProductionPlanCostService service;

    @GetMapping
    @PreAuthorize("hasAuthority('production_plan_cost:view')")
    public PageResponse<PlanCostRow> list(
            @RequestParam(required = false) UUID planItemId,
            @RequestParam(required = false) UUID masterGoodsId,
            @RequestParam(required = false) UUID goodsId,
            @RequestParam(required = false) UUID parentId,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID salesOrderCostItemId,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new PlanCostQueryFilter(planItemId, masterGoodsId, goodsId, parentId,
                supplierId, salesOrderCostItemId, dateFrom, dateTo), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('production_plan_cost:view')")
    public PlanCostRow detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @GetMapping("/aggregate")
    @PreAuthorize("hasAuthority('production_plan_cost:view')")
    public List<PlanCostAggregation> aggregate(
            @RequestParam(required = false) UUID masterGoodsId,
            @RequestParam(required = false) UUID planItemId,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "200") int limit) {
        return service.aggregateByMaster(masterGoodsId, planItemId, dateFrom, dateTo, limit);
    }
}
