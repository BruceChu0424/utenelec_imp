package com.uten.imp.features.stock;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.stock.dto.BalanceRow;
import com.uten.imp.features.stock.dto.MovementRow;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.format.annotation.DateTimeFormat.ISO;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 库存查询 API（库存管理，stock:view）：
 *
 * - GET /api/stock/balances?warehouseId=&goodsId=&page=&size= → 当前余额分页
 * - GET /api/stock/movements?warehouseId=&goodsId=&movementType=&dateFrom=&dateTo=&page=&size= → 出入库流水分页
 */
@RestController
@RequestMapping("/api/stock")
@RequiredArgsConstructor
public class StockQueryController {

    private final StockQueryService service;

    @GetMapping("/balances")
    @PreAuthorize("hasAuthority('stock:view')")
    public PageResponse<BalanceRow> balances(
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) UUID goodsId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.balances(warehouseId, goodsId, page, size);
    }

    @GetMapping("/movements")
    @PreAuthorize("hasAuthority('stock:view')")
    public PageResponse<MovementRow> movements(
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) UUID goodsId,
            @RequestParam(required = false) Short movementType,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE_TIME) OffsetDateTime dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE_TIME) OffsetDateTime dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.movements(warehouseId, goodsId, movementType, dateFrom, dateTo, page, size);
    }
}
