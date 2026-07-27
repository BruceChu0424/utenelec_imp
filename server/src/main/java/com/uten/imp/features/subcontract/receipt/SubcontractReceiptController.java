package com.uten.imp.features.subcontract.receipt;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.subcontract.receipt.dto.ReceiptDetail;
import com.uten.imp.features.subcontract.receipt.dto.ReceiptListItem;
import com.uten.imp.features.subcontract.receipt.dto.ReceiptQueryFilter;
import com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest;
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
import java.util.UUID;

/**
 * 委外进仓单 API（委外管理）。
 *
 * - GET    /api/subcontract/receipts?keyword=&supplierId=&warehouseId=&status=&dateFrom=&dateTo=&page=&size= → 分页
 * - GET    /api/subcontract/receipts/{id}            → 详情（主+明细）
 * - POST   /api/subcontract/receipts                 → 新建（草稿）subcontract_receipt:edit
 * - PUT    /api/subcontract/receipts/{id}            → 编辑（仅草稿）
 * - DELETE /api/subcontract/receipts/{id}            → 删除（草稿/红冲可删；已审核禁删）
 * - POST   /api/subcontract/receipts/{id}/approve    → 审核（正向入库 + 回写订货 + 立应付 + ap_posted）
 * - POST   /api/subcontract/receipts/{id}/reverse    → 红冲（先反立帐，再反向冲销）
 */
@RestController
@RequestMapping("/api/subcontract/receipts")
@RequiredArgsConstructor
public class SubcontractReceiptController {

    private final SubcontractReceiptService service;

    @GetMapping
    @PreAuthorize("hasAuthority('subcontract_receipt:view')")
    public PageResponse<ReceiptListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new ReceiptQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_receipt:view')")
    public ReceiptDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('subcontract_receipt:edit')")
    public ReceiptDetail create(@Valid @RequestBody ReceiptSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_receipt:edit')")
    public ReceiptDetail update(@PathVariable UUID id, @Valid @RequestBody ReceiptSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_receipt:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('subcontract_receipt:edit')")
    public ReceiptDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('subcontract_receipt:edit')")
    public ReceiptDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }
}
