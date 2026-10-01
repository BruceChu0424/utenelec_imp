package com.uten.imp.features.stock.count;

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
    public StockCountRequestController(StockCountRequestService service) { this.service=service; }
    @GetMapping("/scope") public Map<String,Object> scope(@RequestParam(required=false) UUID warehouseId) {
        return service.scope(warehouseId);
    }
    @GetMapping("/candidates") public PageResponse<Map<String,Object>> candidates(@RequestParam UUID warehouseId,
            @RequestParam(defaultValue="") String keyword, @RequestParam(required=false) List<UUID> goodsIds,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="50") int size) {
        return service.candidates(warehouseId,keyword,goodsIds,page,size);
    }
    @GetMapping public PageResponse<Map<String,Object>> list(@RequestParam(required=false) String reviewRoute,
            @RequestParam(required=false) String status, @RequestParam(required=false) UUID warehouseId,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="50") int size) {
        return service.list(reviewRoute,status,warehouseId,page,size);
    }
    @GetMapping("/counts") public Map<String,Object> counts() { return service.counts(); }
    @GetMapping("/{id}") public Map<String,Object> detail(@PathVariable UUID id) { return service.detail(id); }
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
