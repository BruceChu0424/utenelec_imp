package com.uten.imp.features.stock;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.stock.dto.FinishedInboundBatchConfirmRequest;
import com.uten.imp.features.stock.dto.FinishedInboundBatchConfirmResponse;
import com.uten.imp.features.stock.dto.StockDocDetail;
import com.uten.imp.features.stock.dto.FinishedInboundConfirmRequest;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
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
 * - POST   /api/stock/docs                 → 新建（草稿）stock_doc:create
 * - PUT    /api/stock/docs/{id}            → 编辑（仅草稿）
 * - DELETE /api/stock/docs/{id}            → 删除（草稿/红冲可删；已审核禁删）
 * - POST   /api/stock/docs/{id}/approve    → 审核（库存联动：写流水+余额）
 * - POST   /api/stock/docs/{id}/reverse    → 红冲（反向冲销）
 *
 * 查看、创建、编辑、删除、审核、红冲和发料分别使用独立 stock_doc 动作权限。
 */
@RestController
@RequestMapping("/api/stock/docs")
@RequiredArgsConstructor
public class StockDocController {

    private final StockDocService service;
    private final AuditDetailViewRecorder auditViews;

    @GetMapping
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public PageResponse<StockDocListItem> list(
            @RequestParam String docType,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) Short issueStatus,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new StockDocQueryFilter(docType, keyword, warehouseId, status, dateFrom, dateTo,
                departmentId, issueStatus), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public StockDocDetail detail(@PathVariable UUID id) {
        StockDocDetail result = service.detail(id);
        auditViews.record(
                "view_stock_document_detail",
                "stock_documents",
                id,
                result.getBillNo(),
                result.getLegacyId(),
                "库存单据");
        return result;
    }

    @PostMapping
    @PreAuthorize("hasAuthority('stock_doc:create')")
    public StockDocDetail create(@Valid @RequestBody StockDocSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('stock_doc:edit')")
    public StockDocDetail update(@PathVariable UUID id, @Valid @RequestBody StockDocSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('stock_doc:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('stock_doc:approve')")
    public StockDocDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    /** 多张生产成品入库草稿原子全量点收；任一失败则整批回滚。 */
    @PostMapping("/finished-in/confirm-batch")
    @PreAuthorize("hasAuthority('stock_doc:approve')")
    public FinishedInboundBatchConfirmResponse confirmFinishedInboundBatch(
            @Valid @RequestBody FinishedInboundBatchConfirmRequest req) {
        return service.confirmFinishedInboundBatch(req);
    }

    /** 生产报工成品入库：仓库逐行确认实收量后才审核入账。 */
    @PostMapping("/{id}/finished-in/confirm")
    @PreAuthorize("hasAuthority('stock_doc:approve')")
    public StockDocDetail confirmFinishedInbound(
            @PathVariable UUID id,
            @Valid @RequestBody FinishedInboundConfirmRequest req) {
        return service.confirmFinishedInbound(id, req);
    }

    /** 已点收生产成品入库专用红冲：反库存并重建 accepted slice 待点收草稿。 */
    @PostMapping("/{id}/finished-in/reverse")
    @PreAuthorize("hasAuthority('stock_doc:reverse')")
    public StockDocDetail reverseFinishedInbound(@PathVariable UUID id) {
        return service.reverseFinishedInbound(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('stock_doc:reverse')")
    public StockDocDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }

    /** Draft DRAW one-step action: approval and first physical issue share one transaction. */
    @PostMapping("/{id}/approve-and-issue")
    @PreAuthorize("hasAuthority('stock_doc:approve') and hasAuthority('stock_doc:issue')")
    public StockDocDetail approveAndIssue(
            @PathVariable UUID id,
            @Valid @RequestBody StockDocIssueRequest req) {
        return service.approveAndIssue(id, req);
    }

    /** DRAW 分轮出库（部分出库）：按行扣剩余可出量并写库存流水。 */
    @PostMapping("/{id}/issue")
    @PreAuthorize("hasAuthority('stock_doc:issue')")
    public StockDocDetail issue(@PathVariable UUID id, @Valid @RequestBody StockDocIssueRequest req) {
        return service.issue(id, req);
    }

    /** DRAW 取消出库：兼容路径下对称回退已出库量（红冲前须全部取消）。 */
    @PostMapping("/{id}/issue/reverse")
    @PreAuthorize("hasAuthority('stock_doc:reverse_issue')")
    public StockDocDetail reverseIssue(@PathVariable UUID id, @Valid @RequestBody StockDocIssueRequest req) {
        return service.reverseIssue(id, req);
    }
}
