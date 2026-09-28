package com.uten.imp.features.stock.insight;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.stock.insight.dto.CycleCountRow;
import com.uten.imp.features.stock.insight.dto.GoodsInsight;
import com.uten.imp.features.stock.insight.dto.LearningRow;
import com.uten.imp.features.stock.insight.dto.WarehouseHealthPage;
import com.uten.imp.features.stock.insight.dto.WeightAlertPage;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/**
 * 仓库智能分析 (库存分析页, ADR-135 §7.4)。消耗速度、ABC、供应商来料少数排名是报表级数据,
 * 四个清单接口要 stock_report:view; 单货品指标条 (货品详情/库存详情用, 不含供应商层面数字) 要 stock:view。
 *
 * <p>仓库范围 (只作用于 /health 与 /cycle-count; 称重异常与单重学习是货品级口径): warehouseId = 指定仓库
 * (含下级); 否则 warehouseScope=MINE = 我负责的仓库 (与仓库任务中心同一口径); 都不给 = 全部核算仓。
 *
 * <ul>
 *   <li>GET /api/stock/insights/health?warehouseId&amp;warehouseScope&amp;categoryId&amp;keyword&amp;abc
 *       &amp;onlyDead&amp;agedOver180&amp;page&amp;size&amp;sort&amp;order: 呆滞与库龄 (+ 顶部指标 overview + 合计 totals);</li>
 *   <li>GET /cycle-count?warehouseId&amp;warehouseScope&amp;showAll&amp;page&amp;size: 盘点建议 (仓库 × 货品 × 颜色,
 *       默认每仓最多 20 条);</li>
 *   <li>GET /weight-alerts?days=30&amp;kind&amp;supplierId&amp;page&amp;size: 称重异常 (+ 供应商/车间汇总;
 *       kind = 称重来源 RECEIPT/DRAW/... 或 REGIME);</li>
 *   <li>GET /learning?filter=NEEDS_SAMPLE|ALL|MASTER_MISMATCH|DRAW_ONLY|CONFLICT&amp;keyword&amp;page&amp;size:
 *       单重学习工作清单;</li>
 *   <li>GET /goods/{goodsId}: 单货品指标条 (stock:view)。</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/stock/insights")
@RequiredArgsConstructor
public class WarehouseInsightController {

    private final WarehouseInsightService service;

    @GetMapping("/health")
    @PreAuthorize("hasAuthority('stock_report:view')")
    public WarehouseHealthPage health(
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) String warehouseScope,
            @RequestParam(required = false) UUID categoryId,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) String abc,
            @RequestParam(defaultValue = "false") boolean onlyDead,
            @RequestParam(defaultValue = "false") boolean agedOver180,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.health(warehouseId, warehouseScope, categoryId, keyword, abc, onlyDead, agedOver180, page,
                size, sort, order);
    }

    @GetMapping("/cycle-count")
    @PreAuthorize("hasAuthority('stock_report:view')")
    public PageResponse<CycleCountRow> cycleCount(
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) String warehouseScope,
            @RequestParam(defaultValue = "false") boolean showAll,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.cycleCount(warehouseId, warehouseScope, showAll, page, size);
    }

    @GetMapping("/weight-alerts")
    @PreAuthorize("hasAuthority('stock_report:view')")
    public WeightAlertPage weightAlerts(
            @RequestParam(defaultValue = "30") int days,
            @RequestParam(required = false) String kind,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.weightAlerts(days, kind, supplierId, page, size);
    }

    @GetMapping("/learning")
    @PreAuthorize("hasAuthority('stock_report:view')")
    public PageResponse<LearningRow> learning(
            @RequestParam(required = false) String filter,
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.learning(filter, keyword, page, size);
    }

    @GetMapping("/goods/{goodsId}")
    @PreAuthorize("hasAuthority('stock:view')")
    public GoodsInsight goods(@PathVariable UUID goodsId) {
        return service.goods(goodsId);
    }
}
