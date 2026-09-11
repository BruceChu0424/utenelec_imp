package com.uten.imp.features.production.schedule;

import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.schedule.dto.MergePlanRequest;
import com.uten.imp.features.production.schedule.dto.PendingPlanRow;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 生产调度工作台 API（业务链 · 排产段）。
 *
 * <p>GET  /pending      待排产订单行（交货升序，urgent 标红）—— production_plan:view
 * <p>POST /merge-plan   旧合并排产写入口（始终拒绝并引导物料分析联合预览）
 */
@RestController
@RequestMapping("/api/production/schedule")
@RequiredArgsConstructor
public class ProductionScheduleController {

    private final ProductionScheduleService service;

    /** 待排产订单行（服务端分页；keyword 模糊单号/客户/货品；dateFrom/dateTo 交货日期范围；
     *  sort/order 表头排序；status 表头值筛选 urgent/normal）。 */
    @GetMapping("/pending")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public com.uten.imp.common.web.PageResponse<PendingPlanRow> pending(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) java.time.LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) java.time.LocalDate dateTo,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @RequestParam(required = false) String status) {
        return service.pending(page, size, keyword, dateFrom, dateTo, sort, order, status);
    }

    /** 待排产状态 facets（表头值筛选下拉用）：{status:[{value,count,label}]}（紧急/正常）。 */
    @GetMapping("/pending/facets")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public Map<String, List<Map<String, Object>>> pendingFacets(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) java.time.LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) java.time.LocalDate dateTo) {
        return service.pendingFacets(keyword, dateFrom, dateTo);
    }

    /** 待排产计数（生产部工作台徽标）：{"count": n, "urgent": m}。 */
    @GetMapping("/pending-count")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public Map<String, Long> pendingCount() {
        return service.pendingCount();
    }

    /** 已审订单明细 + 每行货品一层 BOM 零件（新建计划单「从订单带明细」弹窗数据源）。 */
    @GetMapping("/order-lines")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public List<com.uten.imp.features.production.schedule.dto.ScheduleOrderLine> orderLines(
            @RequestParam UUID orderId) {
        return service.orderLines(orderId);
    }

    /** 返回 {"planId": "..."}，前端跳计划详情页确认后审核。 */
    @PostMapping("/merge-plan")
    @PreAuthorize("hasAuthority('production_material_analysis:create')")
    public Map<String, UUID> mergePlan(@Valid @RequestBody MergePlanRequest req) {
        throw new com.uten.imp.common.web.ApiException(
                com.uten.imp.common.web.ErrorCode.CONFLICT,
                "合并排产已迁移到物料分析联合预览，请使用 /api/production/material-analyses");
    }

    /** D2 建议完工日期：body {items:[{goodsId,qty}], startDate?} → suggestedDate + 逐货品依据。 */
    @PostMapping("/suggest-finish")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public Map<String, Object> suggestFinish(@RequestBody Map<String, Object> body) {
        List<Map<String, Object>> items = validatedSuggestionItems(body.get("items"));
        LocalDate start = validatedStartDate(body.get("startDate"));
        return service.suggestFinish(items, start);
    }

    private static List<Map<String, Object>> validatedSuggestionItems(Object value) {
        if (!(value instanceof List<?> rawItems)
                || rawItems.isEmpty()
                || rawItems.size() > RequestLimits.DOCUMENT_LINES) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "items 必须是包含 1-" + RequestLimits.DOCUMENT_LINES + " 行的数组");
        }
        List<Map<String, Object>> items = new ArrayList<>(rawItems.size());
        for (int i = 0; i < rawItems.size(); i++) {
            Object rawItem = rawItems.get(i);
            if (!(rawItem instanceof Map<?, ?> item)) {
                throw invalidSuggestionItem(i);
            }
            Object rawGoodsId = item.get("goodsId");
            Object rawQty = item.get("qty");
            try {
                UUID goodsId = UUID.fromString(String.valueOf(rawGoodsId));
                BigDecimal qty = new BigDecimal(String.valueOf(rawQty));
                if (qty.signum() <= 0) {
                    throw invalidSuggestionItem(i);
                }
                items.add(Map.of("goodsId", goodsId.toString(), "qty", qty));
            } catch (IllegalArgumentException ex) {
                throw invalidSuggestionItem(i);
            }
        }
        return items;
    }

    private static LocalDate validatedStartDate(Object value) {
        if (value == null) {
            return null;
        }
        if (!(value instanceof String text)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "startDate 必须是 ISO 日期");
        }
        try {
            return LocalDate.parse(text);
        } catch (DateTimeParseException ex) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "startDate 必须是 ISO 日期");
        }
    }

    private static ApiException invalidSuggestionItem(int index) {
        return new ApiException(
                ErrorCode.VALIDATION_FAILED,
                "items[" + index + "] 必须包含合法 goodsId 和大于 0 的 qty");
    }
}
