package com.uten.imp.features.stock.count;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.common.web.PageResponse;
import jakarta.validation.Valid;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;

@RestController
@RequestMapping("/api/stock/count-requests")
@PreAuthorize("hasAnyAuthority('stock:count:submit','stock:count:finance_review','stock:count:warehouse_review')")
public class StockCountRequestController {
    private final StockCountRequestService service;
    private final AuditDetailViewRecorder auditViews;
    private final WarehouseTaskScopePort warehouseScopes;
    public StockCountRequestController(StockCountRequestService service,AuditDetailViewRecorder auditViews,
                                       WarehouseTaskScopePort warehouseScopes) {
        this.service=service;this.auditViews=auditViews;this.warehouseScopes=warehouseScopes;
    }
    @GetMapping("/scope") public Map<String,Object> scope(@RequestParam(required=false) UUID warehouseId) {
        return service.scope(warehouseId);
    }
    @GetMapping("/candidates") public PageResponse<Map<String,Object>> candidates(@RequestParam UUID warehouseId,
            @RequestParam(defaultValue="") String keyword, @RequestParam(required=false) List<UUID> goodsIds,
            @RequestParam(required=false) UUID categoryId, @RequestParam(defaultValue="false") boolean stockedOnly,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="50") int size) {
        return service.candidates(warehouseId,keyword,goodsIds,categoryId,stockedOnly,page,size);
    }
    /** Existing Java callers keep the unfiltered candidate contract. */
    public PageResponse<Map<String,Object>> candidates(UUID warehouseId,String keyword,List<UUID> goodsIds,int page,int size) {
        return service.candidates(warehouseId,keyword,goodsIds,page,size);
    }
    @GetMapping("/candidate-categories") @PreAuthorize("hasAuthority('stock:count:submit')")
    public List<Map<String,Object>> candidateCategories(@RequestParam UUID warehouseId) {
        return service.candidateCategories(warehouseId);
    }
    @GetMapping("/candidate-category-ids") @PreAuthorize("hasAuthority('stock:count:submit')")
    public List<UUID> candidateCategoryIds(@RequestParam UUID warehouseId,@RequestParam(defaultValue="") String keyword) {
        return service.candidateCategoryIds(warehouseId,keyword);
    }
    /**
     * 盘点申请列表。仓库审核(reviewRoute=WAREHOUSE)是仓库任务, 按仓库数据范围(ADR-149)强制过滤,
     * scopeWarehouseId = 在可选范围内挑一个仓(越界 403); 财务审核与「我提交的」不按仓库范围裁剪。
     */
    @GetMapping public PageResponse<Map<String,Object>> list(@RequestParam(required=false) String reviewRoute,
            @RequestParam(required=false) String status, @RequestParam(required=false) UUID warehouseId,
            @RequestParam(required=false) UUID scopeWarehouseId,
            @RequestParam(required=false) String keyword,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="50") int size) {
        return service.list(reviewRoute,status,warehouseId,page,size,warehouseScopes.current(scopeWarehouseId),keyword);
    }
    /** Java 调用方: 同端点口径(本人仓库数据范围)。 */
    public PageResponse<Map<String,Object>> list(String reviewRoute,String status,UUID warehouseId,
                                               int page,int size) {
        return service.list(reviewRoute,status,warehouseId,page,size,warehouseScopes.current(null));
    }
    /** 待办计数; warehousePending(仓库审核红数, 徽章来源 stockCountWarehouse)与仓库审核列表同一仓库范围。 */
    @GetMapping("/counts") public Map<String,Object> counts(@RequestParam(required=false) UUID scopeWarehouseId) {
        return service.counts(warehouseScopes.current(scopeWarehouseId));
    }
    @GetMapping("/{id}") public Map<String,Object> detail(@PathVariable UUID id) {
        Map<String,Object> detail=service.detail(id);
        auditViews.record("view_stock_count_request_detail","stock_count_requests",id,
                Objects.toString(detail.get("requestNo"),null),null,"库存盘点申请");
        return detail;
    }
    @PostMapping @PreAuthorize("hasAuthority('stock:count:submit')")
    public Map<String,Object> submit(@Valid @RequestBody StockCountDtos.Submit request) { return service.submit(request); }
    @PostMapping("/{id}/approve") public Map<String,Object> approve(@PathVariable UUID id,@Valid @RequestBody StockCountDtos.Decision request) {
        return service.decide(id,"APPROVE",request);
    }
    @PostMapping("/{id}/reject") public Map<String,Object> reject(@PathVariable UUID id,@Valid @RequestBody StockCountDtos.Decision request) {
        return service.decide(id,"REJECT",request);
    }
    @PostMapping("/{id}/cancel") @PreAuthorize("hasAuthority('stock:count:submit')")
    public Map<String,Object> cancel(@PathVariable UUID id,@Valid @RequestBody StockCountDtos.Decision request) {
        return service.decide(id,"CANCEL",request);
    }
}
