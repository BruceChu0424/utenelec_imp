package com.uten.imp.features.master.goods;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.ExportPasswordRequest;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.DownloadContentDisposition;
import com.uten.imp.features.master.goods.dto.BomItemSaveRequest;
import com.uten.imp.features.master.goods.dto.BomItemView;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/**
 * 货品组装信息（BOM）API（基础资料-货品资料 → 详情「组装信息」页签）。
 *
 * - GET    /api/master/goods/{id}/bom              → 组件清单（含组件展示信息 + hasChildren）
 * - POST   /api/master/goods/{id}/bom              → 添加组件（goods:edit，组件编号唯一）
 * - PUT    /api/master/goods/{id}/bom/{itemId}     → 编辑组件行（goods:edit）
 * - DELETE /api/master/goods/{id}/bom/{itemId}     → 删除组件行（goods:edit，软删）
 * - POST   /api/master/goods/{id}/bom/export       → 产品配件清单加密 Excel（goods:export）
 *
 * 组装树的子级由前端对组件 id 再调 GET list 懒加载（组件自身也是货品）。
 */
@RestController
@RequestMapping("/api/master/goods/{id}/bom")
@RequiredArgsConstructor
public class GoodsBomController {

    private final GoodsBomService service;
    private final XlsxExportService xlsxExport;
    private final WorkbookDownloadService workbookDownload;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;

    @GetMapping
    @PreAuthorize("hasAuthority('goods:view')")
    public List<BomItemView> list(@PathVariable UUID id) {
        return service.list(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('goods:edit')")
    public BomItemView create(@PathVariable UUID id, @Valid @RequestBody BomItemSaveRequest req) {
        return service.create(id, req);
    }

    @PutMapping("/{itemId}")
    @PreAuthorize("hasAuthority('goods:edit')")
    public BomItemView update(@PathVariable UUID id, @PathVariable UUID itemId,
                              @Valid @RequestBody BomItemSaveRequest req) {
        return service.update(id, itemId, req);
    }

    @DeleteMapping("/{itemId}")
    @PreAuthorize("hasAuthority('goods:edit')")
    public void delete(@PathVariable UUID id, @PathVariable UUID itemId) {
        service.delete(id, itemId);
    }

    /** 产品配件清单加密 Excel 导出（密码走 body，与主档导出同一套）。 */
    @PostMapping("/export")
    @PreAuthorize("hasAuthority('goods:export')")
    public ResponseEntity<byte[]> export(@PathVariable UUID id,
                                         @Valid @RequestBody ExportPasswordRequest body) {
        ExportPayload payload = service.exportPayload(id);
        byte[] xlsx = xlsxExport.build(payload.columns(), payload.rows());
        byte[] downloadBytes = workbookDownload.protect(xlsx, body.password());
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "export_goods_bom", "master_data", String.valueOf(payload.total()), "success"));
        String filename = "goods_bom.xlsx";
        return ResponseEntity.ok()
                .header("Content-Disposition", DownloadContentDisposition.attachment(filename))
                .header("Content-Type",
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
                .body(downloadBytes);
    }
}
