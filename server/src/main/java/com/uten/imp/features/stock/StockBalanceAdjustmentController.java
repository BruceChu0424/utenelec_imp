package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import com.uten.imp.features.stock.dto.StockBalanceAdjustmentRequest;
import com.uten.imp.features.stock.dto.StockBalanceAdjustmentResult;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 已退役的库存余额快捷入口；旧调用方必须改用送审盘点。
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
        throw new ApiException(ErrorCode.CONFLICT, "库存调整已改为盘点审批，请通过盘点模式录入并提交财务审核");
    }
}
