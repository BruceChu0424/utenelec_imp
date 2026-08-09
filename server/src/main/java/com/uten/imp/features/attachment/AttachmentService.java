package com.uten.imp.features.attachment;

import com.uten.imp.common.storage.BlobStore;
import com.uten.imp.common.storage.StorageService;
import com.uten.imp.common.storage.StorageService.PresignedUpload;
import com.uten.imp.common.storage.StorageService.StoredObject;
import com.uten.imp.common.storage.StorageService.UploadRequest;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.features.attachment.dto.AttachmentConfirmRequest;
import com.uten.imp.features.attachment.dto.AttachmentDto;
import com.uten.imp.features.attachment.dto.AttachmentPresignRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.util.StringUtils;

import java.io.InputStream;
import java.util.List;
import java.util.Locale;
import java.util.UUID;

@Service
@RequiredArgsConstructor
public class AttachmentService {

    private final StorageService storage;
    private final AttachmentRepository repository;
    private final StorageProperties properties;
    private final SecurityContextCurrentUser currentUser;
    private final ObjectProvider<BlobStore> blobStore;

    /** 第一步：校验类型/大小，签发直传 URL + storageKey。不落库（落库在 confirm）。 */
    public PresignedUpload presign(AttachmentPresignRequest request) {
        requireEnabled();
        validateUpload(request.fileName(), request.contentType(), request.sizeBytes());
        return storage.presignUpload(new UploadRequest(
                request.ownerType(), request.fileName(),
                normalizeContentType(request.contentType()), request.sizeBytes()));
    }

    /** 第二步：客户端直传完成后绑定业务单据。校验对象已到位再落库，避免孤儿元信息。 */
    @Transactional
    public AttachmentDto confirm(AttachmentConfirmRequest request) {
        requireEnabled();
        AuthUser user = requireStaff();
        require(user, "attachment:manage");
        validateUpload(request.originalName(), request.contentType(), request.sizeBytes());

        StoredObject obj = storage.describe(request.storageKey());
        if (!obj.exists()) {
            throw new ApiException(ErrorCode.CONFLICT, "上传未完成或已过期，请重新上传");
        }
        long actualSize = obj.size() > 0 ? obj.size() : request.sizeBytes();
        String contentType = StringUtils.hasText(obj.contentType())
                ? obj.contentType() : normalizeContentType(request.contentType());

        Attachment entity = new Attachment();
        entity.setOwnerType(request.ownerType());
        entity.setOwnerId(request.ownerId());
        entity.setStorageKey(request.storageKey());
        entity.setOriginalName(request.originalName());
        entity.setContentType(contentType);
        entity.setSizeBytes(actualSize);
        entity.setSha256(StringUtils.hasText(request.sha256()) ? request.sha256().trim() : null);
        repository.save(entity);
        return toDto(entity);
    }

    /** 列出某业务单据的附件，含即时签发的下载 URL。 */
    @Transactional(readOnly = true)
    public List<AttachmentDto> list(String ownerType, UUID ownerId) {
        requireStaff();
        return repository.findByOwnerTypeAndOwnerIdOrderByCreatedAtAsc(ownerType, ownerId).stream()
                .map(this::toDto)
                .toList();
    }

    /** 删除附件：对象存储删对象 + 删元信息行。上传人本人或持 attachment:manage 者可删。 */
    @Transactional
    public void delete(UUID id) {
        requireEnabled();
        AuthUser user = requireStaff();
        Attachment attachment = repository.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "附件不存在"));
        boolean owner = user.getId().equals(attachment.getCreatedBy());
        if (!owner && !has(user, "attachment:manage")) {
            throw new ApiException(ErrorCode.FORBIDDEN);
        }
        storage.delete(attachment.getStorageKey());
        repository.delete(attachment);
    }

    // ---- 本地后端原始字节 IO（BlobStore 仅 local 模式存在；oss 模式客户端直传 OSS，不走这里）----

    /** local 模式：接收客户端直传字节落盘。oss 模式（无 BlobStore）返回 404，客户端不会调用。 */
    public void storeRaw(String storageKey, InputStream in, long contentLength, String contentType) {
        BlobStore store = blobStore.getIfAvailable();
        if (store == null) {
            throw new ApiException(ErrorCode.NOT_FOUND, "本地直传未启用（provider 非 local）");
        }
        store.store(storageKey, in, contentLength, contentType);
    }

    /** local 模式：打开下载流 + 元信息；oss 模式返回 null（下载走预签名 URL）。 */
    public RawDownload openRaw(String storageKey) {
        BlobStore store = blobStore.getIfAvailable();
        if (store == null) {
            return null;
        }
        Attachment meta = repository.findByStorageKey(storageKey).orElse(null);
        InputStream in = store.read(storageKey);
        String fileName = meta != null && meta.getOriginalName() != null
                ? meta.getOriginalName() : storageKey;
        String contentType = meta != null && meta.getContentType() != null
                ? meta.getContentType() : MediaType.APPLICATION_OCTET_STREAM_VALUE;
        return new RawDownload(in, contentType, fileName);
    }

    /** 本地原始下载载荷（流 + 内容类型 + 文件名）。 */
    public record RawDownload(InputStream stream, String contentType, String fileName) {
    }

    private AttachmentDto toDto(Attachment a) {
        String downloadUrl = null;
        try {
            downloadUrl = storage.presignDownload(a.getStorageKey()).url();
        } catch (Exception ignored) {
            // disabled 后端签发失败时下载 URL 为空，前端按缺失处理。
        }
        return new AttachmentDto(
                a.getId(), a.getOwnerType(), a.getOwnerId(), a.getStorageKey(),
                a.getOriginalName(), a.getContentType(), a.getSizeBytes(),
                a.getCreatedAt(), a.getCreatedBy(), downloadUrl);
    }

    private void requireEnabled() {
        if (!storage.isEnabled()) {
            throw new ApiException(ErrorCode.BUSINESS, "附件存储未启用");
        }
    }

    private void validateUpload(String fileName, String contentType, long size) {
        if (!StringUtils.hasText(fileName)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "文件名不能为空");
        }
        String normalized = normalizeContentType(contentType);
        if (!StringUtils.hasText(normalized)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "缺少文件类型");
        }
        boolean allowed = properties.getAllowedContentTypes().stream()
                .anyMatch(a -> a.equalsIgnoreCase(normalized));
        if (!allowed) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "不支持的文件类型: " + normalized);
        }
        if (size <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "文件大小无效");
        }
        if (size > properties.getMaxBytes()) {
            throw new ApiException(ErrorCode.PAYLOAD_TOO_LARGE,
                    "文件过大，上限 " + properties.getMaxBytes() + " 字节");
        }
    }

    /** 取 Content-Type 主类型（去掉 ; 参数）。 */
    private static String normalizeContentType(String contentType) {
        if (!StringUtils.hasText(contentType)) {
            return "";
        }
        return contentType.split(";")[0].trim().toLowerCase(Locale.ROOT);
    }

    private AuthUser requireStaff() {
        AuthUser user = currentUser.get()
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (user.isVisitor() || user.getEmployeeId() == null) {
            throw new ApiException(ErrorCode.FORBIDDEN);
        }
        return user;
    }

    private static boolean has(AuthUser user, String permission) {
        return user.isSuperAdmin() || user.getPermissions().contains(permission);
    }

    private static void require(AuthUser user, String permission) {
        if (!has(user, permission)) {
            throw new ApiException(ErrorCode.FORBIDDEN);
        }
    }
}
