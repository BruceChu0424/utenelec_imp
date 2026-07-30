package com.uten.imp.features.finance.arap;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.finance.arap.dto.ArApLedgerDetail;
import com.uten.imp.features.finance.arap.dto.ArApLedgerListItem;
import com.uten.imp.features.finance.arap.dto.ArApLedgerQueryFilter;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 应收应付台账 API（钱流管理 · 只读查询）。
 *
 * <p>立帐 / 反立帐由销售/采购/委外审核 Service 跨模块调用 {@link ArApLedgerService}，
 * 不暴露 POST/DELETE 端点（用户不直接编辑台账）。
 *
 * <ul>
 *   <li>GET /api/finance/ar-ap?direction=&sourceDocType=&partyId=&settled=&dateFrom=&dateTo=&page=&size= → 分页</li>
 *   <li>GET /api/finance/ar-ap/{id} → 详情</li>
 * </ul>
 *
 * <p>权限：{@code ar_ap_ledger:view}（V57 种子化，view 给所有部门）。
 */
@RestController
@RequestMapping("/api/finance/ar-ap")
@RequiredArgsConstructor
public class ArApLedgerController {

    private final ArApLedgerQueryService queryService;

    @GetMapping
    @PreAuthorize("hasAuthority('ar_ap_ledger:view')")
    public PageResponse<ArApLedgerListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) String direction,
            @RequestParam(required = false) String sourceDocType,
            @RequestParam(required = false) UUID partyId,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID currencyId,
            @RequestParam(required = false) Boolean settled,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String sourceDocNo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        ArApLedgerQueryFilter f = new ArApLedgerQueryFilter(
                keyword, direction, sourceDocType, partyId, clientId, supplierId, currencyId,
                settled, status, dateFrom, dateTo, sourceDocNo);
        return queryService.list(f, page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('ar_ap_ledger:view')")
    public ArApLedgerDetail detail(@PathVariable UUID id) {
        return queryService.detail(id);
    }
}
