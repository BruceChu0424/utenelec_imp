package com.uten.imp.features.stock;

import com.uten.imp.features.stock.dto.StockBalanceAdjustmentRequest;
import com.uten.imp.features.stock.dto.StockBalanceAdjustmentResult;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 高风险库存余额调整入口。
 *
 * <p>权限单独拆为 stock:balance:adjust，迁移不授予任何部门，只能由权限管理员明确授权。
 */
@RestController
@RequestMapping("/api/stock/balances")
@RequiredArgsConstructor
public class StockBalanceAdjustmentController {

    private final StockBalanceAdjustmentService service;

    @PostMapping("/adjust")
    @PreAuthorize("hasAuthority('stock:balance:adjust')")
    public StockBalanceAdjustmentResult adjust(
            @Valid @RequestBody StockBalanceAdjustmentRequest request) {
        return service.adjust(request);
    }
}
