package com.uten.imp.features.stock;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.stock.dto.StockDocDetail;
import com.uten.imp.features.stock.dto.StockDocListItem;
import com.uten.imp.features.stock.dto.StockDocQueryFilter;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
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
 * 仓库管理统一出入库单据 API（库存管理，9 类 doc_type 共用一套端点）。
 *
 * - GET    /api/stock/docs?docType=&keyword=&warehouseId=&status=&dateFrom=&dateTo=&page=&size= → 分页
 * - GET    /api/stock/docs/{id}            → 详情（主+明细）
 * - POST   /api/stock/docs                 → 新建（草稿）stock_doc:edit
 * - PUT    /api/stock/docs/{id}            → 编辑（仅草稿）
 * - DELETE /api/stock/docs/{id}            → 删除（草稿/红冲可删；已审核禁删）
 * - POST   /api/stock/docs/{id}/approve    → 审核（库存联动：写流水+余额）
 * - POST   /api/stock/docs/{id}/reverse    → 红冲（反向冲销）
 *
 * 权限 stock_doc:view 全员；stock_doc:edit 归 PMC（超管恒有）。
 */
@RestController
@RequestMapping("/api/stock/docs")
@RequiredArgsConstructor
public class StockDocController {

    private final StockDocService service;

    @GetMapping
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public PageResponse<StockDocListItem> list(
            @RequestParam String docType,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(new StockDocQueryFilter(docType, keyword, warehouseId, status, dateFrom, dateTo), page, size);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public StockDocDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('stock_doc:edit')")
    public StockDocDetail create(@Valid @RequestBody StockDocSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('stock_doc:edit')")
    public StockDocDetail update(@PathVariable UUID id, @Valid @RequestBody StockDocSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('stock_doc:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('stock_doc:edit')")
    public StockDocDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('stock_doc:edit')")
    public StockDocDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }
}
