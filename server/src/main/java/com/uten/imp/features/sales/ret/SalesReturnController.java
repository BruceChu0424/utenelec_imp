package com.uten.imp.features.sales.ret;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.sales.ret.dto.ReturnDetail;
import com.uten.imp.features.sales.ret.dto.ReturnListItem;
import com.uten.imp.features.sales.ret.dto.ReturnQueryFilter;
import com.uten.imp.features.sales.ret.dto.ReturnSaveRequest;
import com.uten.imp.features.sales.ret.dto.ReturnQualityDispositionRequest;
import com.uten.imp.features.sales.ret.dto.ReturnQualityItemDto;
import com.uten.imp.features.sales.ret.dto.CustomerDispositionRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 销售退货单 API（销售管理）。
 *
 * - GET    /api/sales/returns               → 分页
 * - GET    /api/sales/returns/{id}          → 详情
 * - POST   /api/sales/returns               → 新建 sales_return:edit
 * - PUT    /api/sales/returns/{id}          → 编辑（仅草稿）
 * - DELETE /api/sales/returns/{id}          → 删除
 * - POST   /api/sales/returns/{id}/approve  → 审核（V189 质检冻结 + 双挂回写 + 立红字应收 + 结案）
 * - POST   /api/sales/returns/{id}/reverse  → 红冲（未处置冻结可受控反向；已处置需走补偿流程）
 */
@RestController
@RequestMapping("/api/sales/returns")
@RequiredArgsConstructor
public class SalesReturnController {

    private final SalesReturnService service;
    private final SalesReturnQualityService qualityService;

    @GetMapping
    @PreAuthorize("hasAuthority('sales_return:view')")
    public PageResponse<ReturnListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) Boolean arPosted,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new ReturnQueryFilter(keyword, clientId, warehouseId, status, arPosted, dateFrom, dateTo), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_return:view')")
    public ReturnDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('sales_return:edit')")
    public ReturnDetail create(@Valid @RequestBody ReturnSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_return:edit')")
    public ReturnDetail update(@PathVariable UUID id, @Valid @RequestBody ReturnSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_return:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('sales_return:edit')")
    public ReturnDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('sales_return:edit')")
    public ReturnDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }

    /**
     * 客户处置确认（V219）：销售确认退款结案/换货/补发/维修后返还。
     * RESHIP/EXCHANGE 重开替换履约预留；REFUND_CLOSED/REPAIR_RETURN 关闭替换需求（不补产）。
     * 确认后禁止整单普通红冲。
     */
    @PostMapping("/{id}/disposition")
    @PreAuthorize("hasAuthority('sales_return:disposition')")
    public ReturnDetail disposition(
            @PathVariable UUID id,
            @Valid @RequestBody CustomerDispositionRequest request) {
        return service.setDisposition(id, request);
    }

    /** Quality-frozen quantities are physically received but are not saleable ATP. */
    @GetMapping("/{id}/quality")
    @PreAuthorize("hasAuthority('sales_return_quality:view')")
    public List<ReturnQualityItemDto> quality(@PathVariable UUID id) {
        return qualityService.list(id);
    }

    /** Releases good stock or records a controlled scrap/rework disposition. */
    @PostMapping("/{id}/quality/{returnItemId}/dispose")
    @PreAuthorize("hasAuthority('sales_return_quality:view')"
            + " and hasAuthority('sales_return_quality:handle')")
    public List<ReturnQualityItemDto> dispose(
            @PathVariable UUID id,
            @PathVariable UUID returnItemId,
            @Valid @RequestBody ReturnQualityDispositionRequest request) {
        return qualityService.dispose(id, returnItemId, request);
    }
}
