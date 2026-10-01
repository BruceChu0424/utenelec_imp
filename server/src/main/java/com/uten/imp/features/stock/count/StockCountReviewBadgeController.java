package com.uten.imp.features.stock.count;

import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/** 复用审批列表的授权与对象范围，不在徽章里另算一套待办数。 */
@RestController
@RequestMapping("/api/stock/count-review-badges")
public class StockCountReviewBadgeController {
    private final StockCountRequestController requests;
    public StockCountReviewBadgeController(StockCountRequestController requests) { this.requests = requests; }

    @GetMapping("/finance")
    @PreAuthorize("hasAuthority('stock:count:finance_review')")
    public Map<String, Long> finance() { return fact("financePending"); }

    @GetMapping("/warehouse")
    @PreAuthorize("hasAuthority('stock:count:warehouse_review')")
    public Map<String, Long> warehouse() { return fact("warehousePending"); }

    private Map<String, Long> fact(String key) {
        Object value = requests.counts().get(key);
        return Map.of("count", value instanceof Number number ? number.longValue() : 0L);
    }
}
