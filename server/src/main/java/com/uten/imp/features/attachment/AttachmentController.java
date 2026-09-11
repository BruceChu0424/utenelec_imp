package com.uten.imp.features.attachment;

import com.uten.imp.features.attachment.dto.AttachmentCategoryRequest;
import com.uten.imp.features.attachment.dto.AttachmentConfirmRequest;
import com.uten.imp.features.attachment.dto.AttachmentDownloadResponse;
import com.uten.imp.features.attachment.dto.AttachmentDto;
import com.uten.imp.features.attachment.dto.AttachmentPresignRequest;
import com.uten.imp.features.attachment.dto.AttachmentPresignResponse;
import com.uten.imp.features.attachment.dto.AttachmentReconciliationApprovalRequest;
import com.uten.imp.features.attachment.dto.AttachmentReconciliationFindingDto;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.core.io.InputStreamResource;
import org.springframework.core.io.Resource;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.UUID;

/**
 * 通用附件接口。控制器只依赖 {@link AttachmentService}（不直连仓储，符合架构边界）。
 *
 * <p>上传两阶段：{@code presign} 拿直传 URL → 客户端 PUT 字节 → {@code confirm} 校验落库。
 * local 后端时直传 URL 指向 {@code /raw/{key}}（service 经 BlobStore 落本地盘）；
 * oss 后端时直传 URL 指向阿里云 OSS（客户端直传，不经本控制器）。
 */
@RestController
@RequestMapping("/api/attachments")
@RequiredArgsConstructor
public class AttachmentController {

    private final AttachmentService service;
    private final AttachmentReconciliationService reconciliationService;
    private final AttachmentPreviewService previewService;

    @PostMapping("/presign")
    @PreAuthorize("hasAuthority('attachment:upload')")
    public AttachmentPresignResponse presign(@Valid @RequestBody AttachmentPresignRequest request) {
        return service.presign(request);
    }

    @PostMapping("/confirm")
    @PreAuthorize("hasAuthority('attachment:upload')")
    public AttachmentDto confirm(@Valid @RequestBody AttachmentConfirmRequest request) {
        return service.confirm(request);
    }

    @GetMapping
    @PreAuthorize("hasAuthority('attachment:view')")
    public List<AttachmentDto> list(@RequestParam String ownerType,
                                    @RequestParam UUID ownerId) {
        return service.list(ownerType, ownerId);
    }

    @GetMapping("/{id}/download-grant")
    @PreAuthorize("hasAuthority('attachment:download')")
    public AttachmentDownloadResponse downloadGrant(@PathVariable UUID id) {
        return service.downloadGrant(id);
    }

    /**
     * Office 文档在线预览：服务端 LibreOffice 转 PDF 后以私有、不落缓存的响应返回。
     * 门槛与下载授权相同（attachment:download + owner 策略）；服务器未装转换组件、
     * 超时或转换失败返回业务错误，客户端回落为下载原件。
     */
    @GetMapping("/{id}/preview")
    @PreAuthorize("hasAuthority('attachment:download')")
    public ResponseEntity<Resource> preview(@PathVariable UUID id) throws java.io.IOException {
        AttachmentPreviewService.RenderedPreview rendered = previewService.render(id);
        String encoded = URLEncoder.encode(rendered.fileName(), StandardCharsets.UTF_8)
                .replace("+", "%20");
        return ResponseEntity.ok()
                .contentType(MediaType.APPLICATION_PDF)
                .contentLength(rendered.sizeBytes())
                .header(HttpHeaders.CONTENT_DISPOSITION, "inline; filename*=UTF-8''" + encoded)
                .header("X-Content-Type-Options", "nosniff")
                .header(HttpHeaders.CACHE_CONTROL, "private, no-store")
                .body(new InputStreamResource(java.nio.file.Files.newInputStream(rendered.file())));
    }

    /**
     * 上传完成后设置/清除分类：分类是可选标注，不在上传前询问，也不改变文件与访问范围。
     * 对象授权与删除同一条路径（{@code requireCanManageForUpdate}），
     * 因此单据被审核锁定/红冲后分类同样只读；空值 = 清除分类。
     */
    @PutMapping("/{id}/category")
    @PreAuthorize("hasAuthority('attachment:upload')")
    public AttachmentDto setCategory(@PathVariable UUID id,
                                     @Valid @RequestBody AttachmentCategoryRequest request) {
        return service.setCategory(id, request.category());
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('attachment:delete')")
    @ResponseStatus(HttpStatus.ACCEPTED)
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @GetMapping("/reconciliation/findings")
    @PreAuthorize("hasAuthority('attachment:reconcile:view')")
    public List<AttachmentReconciliationFindingDto> reconciliationFindings() {
        return reconciliationService.listOpen();
    }

    @PostMapping("/reconciliation/findings/{id}/approve-delete")
    @PreAuthorize("hasAuthority('attachment:reconcile:approve_delete')")
    @ResponseStatus(HttpStatus.ACCEPTED)
    public void approveReconciliationDelete(
            @PathVariable UUID id,
            @Valid @RequestBody AttachmentReconciliationApprovalRequest request) {
        reconciliationService.approveDelete(id, request.approvalReference());
    }

    // ---- local 后端的原始字节端点（oss 模式下客户端直传 OSS，不调用这里；返回 404）----

    @PutMapping("/raw/{key}")
    @PreAuthorize("hasAuthority('attachment:upload')")
    public ResponseEntity<Void> uploadRaw(
            @PathVariable String key,
            @RequestHeader("X-Uten-Attachment-Upload-Token") String uploadToken,
            HttpServletRequest request)
            throws java.io.IOException {
        service.storeRaw(key, uploadToken, request.getInputStream(),
                request.getContentLengthLong(), request.getContentType());
        return ResponseEntity.noContent().build();
    }

    @GetMapping("/raw/{key}")
    @PreAuthorize("hasAuthority('attachment:download')")
    public ResponseEntity<Resource> downloadRaw(@PathVariable String key) {
        AttachmentService.RawDownload download = service.openRaw(key);
        if (download == null) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND).build();
        }
        MediaType mediaType;
        try {
            mediaType = MediaType.parseMediaType(download.contentType());
        } catch (Exception e) {
            mediaType = MediaType.APPLICATION_OCTET_STREAM;
        }
        String encoded = URLEncoder.encode(download.fileName(), StandardCharsets.UTF_8)
                .replace("+", "%20");
        return ResponseEntity.ok()
                .contentType(mediaType)
                .contentLength(download.sizeBytes())
                .header(HttpHeaders.CONTENT_DISPOSITION, "attachment; filename*=UTF-8''" + encoded)
                .header("X-Content-Type-Options", "nosniff")
                // 授权后才可读的档案文件（合同/证件/报销发票）不得进浏览器磁盘缓存
                .header(HttpHeaders.CACHE_CONTROL, "private, no-store")
                .body(new InputStreamResource(download.stream()));
    }
}
