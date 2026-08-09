package com.uten.imp.features.attachment;

import com.uten.imp.common.storage.StorageService.PresignedUpload;
import com.uten.imp.features.attachment.dto.AttachmentConfirmRequest;
import com.uten.imp.features.attachment.dto.AttachmentDto;
import com.uten.imp.features.attachment.dto.AttachmentPresignRequest;
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
import org.springframework.web.bind.annotation.RequestParam;
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

    @PostMapping("/presign")
    @PreAuthorize("hasAuthority('attachment:manage')")
    public PresignedUpload presign(@Valid @RequestBody AttachmentPresignRequest request) {
        return service.presign(request);
    }

    @PostMapping("/confirm")
    @PreAuthorize("hasAuthority('attachment:manage')")
    public AttachmentDto confirm(@Valid @RequestBody AttachmentConfirmRequest request) {
        return service.confirm(request);
    }

    @GetMapping
    @PreAuthorize("hasAuthority('attachment:view')")
    public List<AttachmentDto> list(@RequestParam String ownerType,
                                    @RequestParam UUID ownerId) {
        return service.list(ownerType, ownerId);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('attachment:manage')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    // ---- local 后端的原始字节端点（oss 模式下客户端直传 OSS，不调用这里；返回 404）----

    @PutMapping("/raw/{key}")
    public ResponseEntity<Void> uploadRaw(@PathVariable String key, HttpServletRequest request)
            throws java.io.IOException {
        service.storeRaw(key, request.getInputStream(),
                request.getContentLengthLong(), request.getContentType());
        return ResponseEntity.noContent().build();
    }

    @GetMapping("/raw/{key}")
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
                .header(HttpHeaders.CONTENT_DISPOSITION, "inline; filename*=UTF-8''" + encoded)
                .body(new InputStreamResource(download.stream()));
    }
}
