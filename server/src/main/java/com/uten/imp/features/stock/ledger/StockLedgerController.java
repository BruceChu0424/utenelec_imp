package com.uten.imp.features.stock.ledger;

import com.uten.imp.features.stock.ledger.dto.StockLedgerPage;
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
import java.util.UUID;

/**
 * 货品出入库流水 (存货明细账, ADR-135 §7.1), stock:view。
 *
 * <p>GET /api/stock/goods/{goodsId}/ledger?warehouseId=&colorId=&colorNull=&dateFrom=&dateTo=
 * &movementTypes=1,3,W&direction=&includeWeightAdjustments=&page=&size= → {@link StockLedgerPage}。
 * 日期是业务日 (yyyy-MM-dd, 上海时区, dateTo 含当天); size 最多 100。
 * 往来方名称按来源单据查看权限遮挡, 金额按 goods:cost:view 遮挡。
 */
@RestController
@RequestMapping("/api/stock/goods")
@RequiredArgsConstructor
public class StockLedgerController {

    private final StockLedgerQueryService service;

    @GetMapping("/{goodsId}/ledger")
    @PreAuthorize("hasAuthority('stock:view')")
    public StockLedgerPage ledger(
            @PathVariable UUID goodsId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) UUID colorId,
            @RequestParam(defaultValue = "false") boolean colorNull,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String movementTypes,
            @RequestParam(required = false) Short direction,
            @RequestParam(defaultValue = "false") boolean includeWeightAdjustments,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.ledger(goodsId, warehouseId, colorId, colorNull, dateFrom, dateTo, movementTypes,
                direction, includeWeightAdjustments, page, size);
    }
}
