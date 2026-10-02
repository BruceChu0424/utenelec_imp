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
            @RequestParam(required=false) UUID categoryId,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="50") int size) {
        return service.candidates(warehouseId,keyword,goodsIds,categoryId,page,size);
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
    @GetMapping public PageResponse<Map<String,Object>> list(@RequestParam(required=false) String reviewRoute,
            @RequestParam(required=false) String status, @RequestParam(required=false) UUID warehouseId,
            @RequestParam(defaultValue="") String warehouseScope,@RequestParam(required=false) UUID scopeWarehouseId,
            @RequestParam(required=false) String keyword,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="50") int size) {
        return service.list(reviewRoute,status,warehouseId,page,size,warehouseScopes.resolve(warehouseScope,scopeWarehouseId),keyword);
    }
    public PageResponse<Map<String,Object>> list(String reviewRoute,String status,UUID warehouseId,
                                               String warehouseScope,UUID scopeWarehouseId,int page,int size) {
        return service.list(reviewRoute,status,warehouseId,page,size,warehouseScopes.resolve(warehouseScope,scopeWarehouseId));
    }
    /** No task-center filter for existing callers and global badge counts. */
    public PageResponse<Map<String,Object>> list(String reviewRoute,String status,UUID warehouseId,
                                               int page,int size) {
        return service.list(reviewRoute,status,warehouseId,page,size);
    }
    @GetMapping("/counts") public Map<String,Object> counts() { return service.counts(); }
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
