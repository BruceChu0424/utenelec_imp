package com.uten.imp.features.attachment;

import com.uten.imp.common.storage.BlobStore;
import com.uten.imp.common.storage.StorageService;
import com.uten.imp.common.storage.StorageService.PresignedUpload;
import com.uten.imp.common.storage.StorageService.StoredObject;
import com.uten.imp.common.storage.StorageService.UploadRequest;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.audit.AuditService;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.features.attachment.AttachmentUploadGrantService.Grant;
import com.uten.imp.features.attachment.dto.AttachmentConfirmRequest;
import com.uten.imp.features.attachment.dto.AttachmentDownloadResponse;
import com.uten.imp.features.attachment.dto.AttachmentDto;
import com.uten.imp.features.attachment.dto.AttachmentPresignRequest;
import com.uten.imp.features.attachment.dto.AttachmentPresignResponse;
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
import java.util.Objects;
import java.util.UUID;

@Service
@RequiredArgsConstructor
public class AttachmentService {

    private final StorageService storage;
    private final AttachmentRepository repository;
    private final StorageProperties properties;
    private final SecurityContextCurrentUser currentUser;
    private final ObjectProvider<BlobStore> blobStore;
    private final List<AttachmentOwnerAccessPolicy> ownerPolicies;
    private final AttachmentUploadGrantService uploadGrants;
    private final AuditService audit;
    private final AttachmentConfirmTransaction confirmTransaction;

    /**
     * 第一步：在业务对象权限校验后签发上传地址和短期确认授权。授权把用户、业务对象、
     * storageKey、大小和类型绑定在一起，不能用于重绑其他单据或覆盖其他对象。
     */
    public AttachmentPresignResponse presign(AttachmentPresignRequest request) {
        requireEnabled();
        AuthUser user = requireStaff();
        require(user, "attachment:manage");

        String ownerType = normalizeOwnerType(request.ownerType());
        String fileName = request.fileName().trim();
        String contentType = normalizeContentType(request.contentType());
        validateUpload(fileName, contentType, request.sizeBytes());
        policy(ownerType).requireCanManage(request.ownerId(), user);

        PresignedUpload upload = storage.presignUpload(new UploadRequest(
                ownerType, fileName, contentType, request.sizeBytes()));
        Grant grant = new Grant(
                upload.storageKey(), ownerType, request.ownerId(), user.getId(), fileName,
                contentType, request.sizeBytes(), upload.expiresAt());
        return new AttachmentPresignResponse(
                upload.storageKey(), upload.url(), upload.method(), upload.headers(),
                upload.expiresAt(), uploadGrants.issue(grant));
    }

    /** 第二步：校验签发上下文和对象实际元信息后才把对象绑定到业务单据。 */
    public AttachmentDto confirm(AttachmentConfirmRequest request) {
        requireEnabled();
        AuthUser user = requireStaff();
        require(user, "attachment:manage");

        String ownerType = normalizeOwnerType(request.ownerType());
        String fileName = request.originalName().trim();
        String contentType = normalizeContentType(request.contentType());
        validateUpload(fileName, contentType, request.sizeBytes());

        Grant grant = uploadGrants.verifySigned(request.confirmToken());
        requireGrantMatches(grant, request.storageKey(), ownerType, request.ownerId(),
                user.getId(), fileName, contentType, request.sizeBytes());
        AttachmentOwnerAccessPolicy ownerPolicy = policy(ownerType);
        ownerPolicy.requireCanManage(request.ownerId(), user);

        Attachment existing = repository.findByStorageKey(request.storageKey()).orElse(null);
        if (existing != null) {
            if (sameBinding(existing, grant) && user.getId().equals(existing.getCreatedBy())) {
                return toDto(existing); // confirm 响应丢失后的安全重试。
            }
            throw new ApiException(ErrorCode.CONFLICT, "该上传对象已经绑定，不能重复使用");
        }
        // Only a first-time binding must still be inside the upload window.
        // A byte-for-byte identical retry may safely return the persisted fact
        // after expiry when the original HTTP response was lost.
        uploadGrants.requireUnexpired(grant);

        StoredObject obj = storage.describe(request.storageKey());
        if (!obj.exists()) {
            throw new ApiException(ErrorCode.CONFLICT, "上传未完成或已过期，请重新上传");
        }
        if (obj.size() <= 0 || obj.size() != request.sizeBytes()
                || obj.size() > properties.getMaxBytes()) {
            throw new ApiException(ErrorCode.CONFLICT, "上传对象的实际大小与签发信息不一致，请重新上传");
        }
        String actualContentType = normalizeContentType(obj.contentType());
        if (StringUtils.hasText(actualContentType) && !actualContentType.equals(contentType)) {
            throw new ApiException(ErrorCode.CONFLICT, "上传对象的实际文件类型与签发信息不一致，请重新上传");
        }
        AttachmentContentInspector.Inspection inspection = AttachmentContentInspector.inspect(
                storage.openForValidation(request.storageKey(), obj.versionId()),
                obj.size(), fileName, contentType);

        Attachment entity = confirmTransaction.persist(
                grant, user, ownerPolicy, obj,
                StringUtils.hasText(actualContentType) ? actualContentType : contentType,
                inspection.sha256());
        return toDto(entity);
    }

    /** 列出业务单据附件；通用权限和业务对象范围必须同时满足。 */
    @Transactional(readOnly = true)
    public List<AttachmentDto> list(String rawOwnerType, UUID ownerId) {
        AuthUser user = requireStaff();
        require(user, "attachment:view");
        String ownerType = normalizeOwnerType(rawOwnerType);
        policy(ownerType).requireCanView(ownerId, user);
        return repository.findByOwnerTypeAndOwnerIdOrderByCreatedAtAsc(ownerType, ownerId).stream()
                .map(this::toDto)
                .toList();
    }

    /** Issues a fresh short-lived URL only after object-level authorization. */
    @Transactional(readOnly = true)
    public AttachmentDownloadResponse downloadGrant(UUID id) {
        requireEnabled();
        AuthUser user = requireStaff();
        require(user, "attachment:view");
        Attachment attachment = repository.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "Attachment not found"));
        policy(attachment.getOwnerType()).requireCanView(attachment.getOwnerId(), user);

        StorageService.PresignedDownload grant = storage.presignDownload(
                attachment.getStorageKey(), attachment.getStorageVersion());
        audit.logExplicit(user.getId(), user.getLoginAccount(),
                "attachment_download_grant", "attachments", id.toString(), storage.backend());
        return new AttachmentDownloadResponse(grant.url(), grant.expiresAt());
    }

    /** 删除时先验证并刷新 DB 删除，再删对象；对象删除失败会令事务回滚并保留可重试元数据。 */
    @Transactional
    public void delete(UUID id) {
        requireEnabled();
        AuthUser user = requireStaff();
        require(user, "attachment:manage");
        Attachment attachment = repository.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "附件不存在"));
        policy(attachment.getOwnerType()).requireCanManageForUpdate(attachment.getOwnerId(), user);
        repository.delete(attachment);
        repository.flush();
        storage.delete(attachment.getStorageKey(), attachment.getStorageVersion());
    }

    /** local 模式原始字节上传；必须携带 presign 返回的一次性语义授权。 */
    public void storeRaw(String storageKey, String uploadToken, InputStream in,
                         long contentLength, String rawContentType) {
        requireEnabled();
        AuthUser user = requireStaff();
        require(user, "attachment:manage");
        Grant grant = uploadGrants.verify(uploadToken);
        String contentType = normalizeContentType(rawContentType);
        requireGrantMatches(grant, storageKey, grant.ownerType(), grant.ownerId(), user.getId(),
                grant.originalName(), contentType, contentLength);
        validateUpload(grant.originalName(), contentType, contentLength);
        policy(grant.ownerType()).requireCanManage(grant.ownerId(), user);
        if (repository.existsByStorageKey(storageKey)) {
            throw new ApiException(ErrorCode.CONFLICT, "该上传对象已经绑定，不能覆盖");
        }

        BlobStore store = blobStore.getIfAvailable();
        if (store == null) {
            throw new ApiException(ErrorCode.NOT_FOUND, "本地直传未启用（provider 不是 local）");
        }
        try {
            store.store(storageKey, in, contentLength, contentType);
        } catch (IllegalStateException e) {
            throw new ApiException(ErrorCode.CONFLICT, "附件写入失败或对象已存在，请重新上传");
        }
        StoredObject stored = storage.describe(storageKey);
        if (!stored.exists() || stored.size() != contentLength) {
            throw new ApiException(ErrorCode.CONFLICT, "附件实际字节数与签发信息不一致，请重新上传");
        }
    }

    /** local 模式下载；storageKey 必须先解析到元数据并通过业务对象查看权限。 */
    @Transactional(readOnly = true)
    public RawDownload openRaw(String storageKey) {
        AuthUser user = requireStaff();
        require(user, "attachment:view");
        Attachment meta = repository.findByStorageKey(storageKey)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "附件不存在"));
        policy(meta.getOwnerType()).requireCanView(meta.getOwnerId(), user);

        BlobStore store = blobStore.getIfAvailable();
        if (store == null) {
            return null;
        }
        InputStream in;
        try {
            in = store.read(storageKey);
        } catch (IllegalStateException e) {
            throw new ApiException(ErrorCode.NOT_FOUND, "附件对象不存在");
        }
        String fileName = meta.getOriginalName() != null ? meta.getOriginalName() : storageKey;
        String contentType = meta.getContentType() != null
                ? meta.getContentType() : MediaType.APPLICATION_OCTET_STREAM_VALUE;
        return new RawDownload(in, contentType, fileName);
    }

    public record RawDownload(InputStream stream, String contentType, String fileName) {
    }

    private AttachmentDto toDto(Attachment a) {
        return new AttachmentDto(
                a.getId(), a.getOwnerType(), a.getOwnerId(), a.getStorageKey(),
                a.getOriginalName(), a.getContentType(), a.getSizeBytes(),
                a.getCreatedAt(), a.getCreatedBy(), null);
    }

    private AttachmentOwnerAccessPolicy policy(String rawOwnerType) {
        String ownerType = normalizeOwnerType(rawOwnerType);
        List<AttachmentOwnerAccessPolicy> matches = ownerPolicies.stream()
                .filter(candidate -> ownerType.equalsIgnoreCase(candidate.ownerType()))
                .toList();
        if (matches.size() != 1) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "不支持的附件业务类型: " + ownerType);
        }
        return matches.getFirst();
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
                .anyMatch(allowedType -> allowedType.equalsIgnoreCase(normalized));
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

    private static void requireGrantMatches(
            Grant grant, String storageKey, String ownerType, UUID ownerId, UUID userId,
            String originalName, String contentType, long sizeBytes) {
        if (!Objects.equals(grant.storageKey(), storageKey)
                || !Objects.equals(grant.ownerType(), ownerType)
                || !Objects.equals(grant.ownerId(), ownerId)
                || !Objects.equals(grant.userId(), userId)
                || !Objects.equals(grant.originalName(), originalName)
                || !Objects.equals(grant.contentType(), contentType)
                || grant.sizeBytes() != sizeBytes) {
            throw new ApiException(ErrorCode.FORBIDDEN, "附件上传授权与本次请求不匹配，请重新上传");
        }
    }

    static boolean sameBinding(Attachment attachment, Grant grant) {
        return Objects.equals(attachment.getStorageKey(), grant.storageKey())
                && Objects.equals(attachment.getOwnerType(), grant.ownerType())
                && Objects.equals(attachment.getOwnerId(), grant.ownerId())
                && Objects.equals(attachment.getOriginalName(), grant.originalName())
                && Objects.equals(attachment.getContentType(), grant.contentType())
                && attachment.getSizeBytes() == grant.sizeBytes();
    }

    private static String normalizeOwnerType(String ownerType) {
        if (!StringUtils.hasText(ownerType)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "附件业务类型不能为空");
        }
        return ownerType.trim().toUpperCase(Locale.ROOT);
    }

    private static String normalizeContentType(String contentType) {
        if (!StringUtils.hasText(contentType)) {
            return "";
        }
        return contentType.split(";", 2)[0].trim().toLowerCase(Locale.ROOT);
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
