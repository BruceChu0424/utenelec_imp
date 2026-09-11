package com.uten.imp.features.attachment;

import com.uten.imp.application.port.AttachmentAccessPort;
import com.uten.imp.application.port.AttachmentAccessPort.AttachmentView;
import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.storage.BlobStore;
import com.uten.imp.common.storage.StorageService;
import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.common.storage.StorageService.PresignedUpload;
import com.uten.imp.common.storage.StorageService.StoredObject;
import com.uten.imp.common.storage.StorageService.UploadRequest;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.features.attachment.AttachmentMalwareScanner.ScanResult;
import com.uten.imp.features.attachment.AttachmentMalwareScanner.Verdict;
import com.uten.imp.features.attachment.AttachmentUploadGrantService.Grant;
import com.uten.imp.features.attachment.dto.AttachmentConfirmRequest;
import com.uten.imp.features.attachment.dto.AttachmentDownloadResponse;
import com.uten.imp.features.attachment.dto.AttachmentDto;
import com.uten.imp.features.attachment.dto.AttachmentPresignRequest;
import com.uten.imp.features.attachment.dto.AttachmentPresignResponse;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.util.StringUtils;

import java.io.InputStream;
import java.time.Instant;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.UUID;

/**
 * 附件服务：presign 预留配额 → confirm（大小/类型校验 + 内容检查 + 恶意软件扫描 + 暂存提升至 final 命名空间并提交元数据）
 * → 列表/下载/软删除（删除走 outbox 与对象存储解耦）。所有操作经 owner 访问策略 + 签名 grant 双重校验。
 */
@Service
@RequiredArgsConstructor
public class AttachmentService implements AttachmentAccessPort {

    /**
     * 可当头像的图片类型：客户端（Flutter/dart:ui）能直接解码的五种位图。
     * 上传白名单里的 tiff/heic/svg 虽然也是 {@code image/*}，但解码不了，不许选为头像。
     */
    private static final java.util.Set<String> RENDERABLE_AVATAR_TYPES = java.util.Set.of(
            "image/jpeg", "image/png", "image/gif", "image/webp", "image/bmp");

    private final StorageService storage;
    private final AttachmentRepository repository;
    private final StorageProperties properties;
    private final SecurityContextCurrentUser currentUser;
    private final List<AttachmentOwnerAccessPolicy> ownerPolicies;
    private final AttachmentUploadGrantService uploadGrants;
    private final AuditService audit;
    private final AttachmentConfirmTransaction confirmTransaction;
    private final AttachmentUploadSafetyGate uploadSafetyGate;
    private final AttachmentUploadSessionStore uploadSessions;
    private final AttachmentMalwareScanner malwareScanner;
    private final AttachmentObjectOutboxStore objectOutbox;
    private final StorageProviderRegistry storageProviders;
    private final AttachmentDownloadVerifier downloadVerifier;

    @Override
    @Transactional(readOnly = true)
    public java.util.Optional<AttachmentAccessPort.AvatarContent> openSelectedAvatar(String ownerType, UUID ownerId) {
        AuthUser user = requireStaff();
        String type = normalizeOwnerType(ownerType);
        policy(type).requireCanViewAvatar(ownerId, user);
        List<Attachment> selected = repository.findByOwnerTypeAndOwnerIdAndLifecycleStateOrderByCreatedAtAsc(
                        type, ownerId, AttachmentLifecycleState.CLEAN).stream()
                .filter(Attachment::isAvatar).toList();
        if (selected.isEmpty()) return java.util.Optional.empty();
        if (selected.size() != 1) throw new ApiException(ErrorCode.CONFLICT, "Selected avatar identity is not unique");
        Attachment image = selected.getFirst();
        String contentType=normalizeContentType(image.getContentType());
        if (contentType==null || !RENDERABLE_AVATAR_TYPES.contains(contentType)) return java.util.Optional.empty();
        InputStream input = downloadVerifier.open(image);
        auditDownloadOrClose(input,user,"attachment_avatar_download",image.getId());
        return java.util.Optional.of(new AttachmentAccessPort.AvatarContent(input, image.getContentType(),
                image.getOriginalName(), image.getSizeBytes(), image.getSha256()));
    }

    /** Reserves quota before returning an upload-only staging capability. */
    public AttachmentPresignResponse presign(AttachmentPresignRequest request) {
        uploadSafetyGate.requireUploadEnabled();
        AuthUser user = requireStaff();
        require(user, "attachment:upload");

        String ownerType = normalizeOwnerType(request.ownerType());
        String fileName = request.fileName().trim();
        String contentType = normalizeContentType(request.contentType());
        validateUpload(fileName, contentType, request.sizeBytes());
        policy(ownerType).requireCanManage(request.ownerId(), user);

        PresignedUpload upload = storage.presignUpload(new UploadRequest(
                ownerType, fileName, contentType, request.sizeBytes()));
        Instant canonicalExpiry = AttachmentUploadGrantService.canonicalExpiry(upload.expiresAt());
        Grant grant = new Grant(
                upload.storageKey(), ownerType, request.ownerId(), user.getId(), fileName,
                contentType, request.sizeBytes(), canonicalExpiry);
        String confirmToken = uploadGrants.issue(grant);
        uploadSessions.reserve(grant, storage.backend());
        return new AttachmentPresignResponse(
                upload.storageKey(), upload.url(), upload.method(), upload.headers(),
                upload.formFields(), canonicalExpiry, confirmToken);
    }

    /** Scans staging bytes, promotes one pinned version, then commits clean metadata. */
    public AttachmentDto confirm(AttachmentConfirmRequest request) {
        uploadSafetyGate.requireUploadEnabled();
        AuthUser user = requireStaff();
        require(user, "attachment:upload");

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
            if (existing.getLifecycleState() == AttachmentLifecycleState.CLEAN
                    && sameBinding(existing, grant)
                    && user.getId().equals(existing.getCreatedBy())) {
                return toDto(existing);
            }
            throw new ApiException(ErrorCode.CONFLICT,
                    "The uploaded object is already bound and cannot be reused");
        }

        uploadGrants.requireUnexpired(grant);
        AttachmentUploadSessionStore.UploadSession session = uploadSessions.claimForScan(grant);
        try {
            StorageService objectStorage = storageProviders.require(session.storageProvider());
            StoredObject stagingObject = objectStorage.describe(request.storageKey());
            if (!stagingObject.exists()) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "Attachment upload is not complete; upload before confirming");
            }
            if (stagingObject.size() <= 0 || stagingObject.size() != request.sizeBytes()
                    || stagingObject.size() > properties.getMaxBytes()) {
                reject(session, stagingObject, "SIZE_MISMATCH", null);
                throw new ApiException(ErrorCode.CONFLICT,
                        "Uploaded object size does not match its signed policy");
            }
            String actualContentType = normalizeContentType(stagingObject.contentType());
            if (StringUtils.hasText(actualContentType) && !actualContentType.equals(contentType)) {
                reject(session, stagingObject, "CONTENT_TYPE_MISMATCH", null);
                throw new ApiException(ErrorCode.CONFLICT,
                        "Uploaded object content type does not match its signed policy");
            }
            uploadSessions.recordStaging(
                    session.id(), stagingObject.versionId(), stagingObject.eTag(), null);

            AttachmentContentInspector.Inspection inspection;
            try {
                inspection = AttachmentContentInspector.inspect(
                        objectStorage.openForValidation(request.storageKey(), stagingObject.versionId()),
                        stagingObject.size(), fileName, contentType);
            } catch (ApiException invalidContent) {
                reject(session, stagingObject, "CONTENT_INSPECTION_REJECTED", null);
                throw invalidContent;
            }
            if (stagingObject.contentSha256()!=null && !stagingObject.contentSha256().equals(inspection.sha256())) {
                reject(session,stagingObject,"STAGED_DIGEST_CHANGED",null);
                throw new ApiException(ErrorCode.CONFLICT,"Uploaded object digest changed before scanning");
            }
            uploadSessions.recordStaging(
                    session.id(), stagingObject.versionId(), stagingObject.eTag(),
                    inspection.sha256());

            ScanResult scan = malwareScanner.scan(
                    objectStorage.openForValidation(request.storageKey(), stagingObject.versionId()),
                    stagingObject.size());
            if (scan.verdict() != Verdict.CLEAN) {
                reject(session, stagingObject, "MALWARE_DETECTED", scan);
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "Attachment was quarantined by malware scanning");
            }

            StoredObject finalObject = objectStorage.promoteToFinal(
                    request.storageKey(), stagingObject);
            if (!finalObject.exists() || finalObject.size() != stagingObject.size()
                    || (finalObject.contentSha256()!=null && !finalObject.contentSha256().equals(inspection.sha256()))) {
                throw new IllegalStateException("Promoted attachment metadata is inconsistent");
            }
            Attachment entity = confirmTransaction.persist(
                    session.id(), grant, user, ownerPolicy, stagingObject, finalObject,
                    StringUtils.hasText(actualContentType) ? actualContentType : contentType,
                    inspection.sha256(), scan, request.category(), session.storageProvider());
            return toDto(entity);
        } catch (AttachmentScanUnavailableException unavailable) {
            uploadSessions.releaseAfterTransientFailure(session.id(), "SCANNER_UNAVAILABLE");
            throw new ApiException(ErrorCode.BUSINESS,
                    "Attachment scanning is unavailable; the object remains quarantined");
        } catch (ApiException error) {
            uploadSessions.releaseAfterTransientFailure(session.id(), "CONFIRM_RETRYABLE");
            throw error;
        } catch (RuntimeException error) {
            uploadSessions.releaseAfterTransientFailure(
                    session.id(), "PROMOTION_OR_DATABASE_FAILURE");
            throw error;
        }
    }

    @Transactional(readOnly = true)
    public List<AttachmentDto> list(String rawOwnerType, UUID ownerId) {
        AuthUser user = requireStaff();
        require(user, "attachment:view");
        String ownerType = normalizeOwnerType(rawOwnerType);
        policy(ownerType).requireCanView(ownerId, user);
        return repository.findByOwnerTypeAndOwnerIdAndLifecycleStateOrderByCreatedAtAsc(
                        ownerType, ownerId, AttachmentLifecycleState.CLEAN).stream()
                .map(this::toDto)
                .toList();
    }

    @Override
    @Transactional(readOnly = true)
    public List<AttachmentView> listVisible(String rawOwnerType, UUID ownerId) {
        return list(rawOwnerType, ownerId).stream()
                .map(attachment -> new AttachmentView(
                        attachment.id(), attachment.ownerType(), attachment.ownerId(),
                        attachment.storageKey(), attachment.originalName(),
                        attachment.contentType(), attachment.sizeBytes(),
                        attachment.uploadedAt(), attachment.uploadedBy(),
                        attachment.downloadUrl(), attachment.category(), attachment.avatar()))
                .toList();
    }

    @Override
    @Transactional
    public String selectAvatar(String rawOwnerType, UUID ownerId, UUID attachmentId) {
        AuthUser user = requireStaff();
        // 设为头像是 owner 专用动作，不借用附件上传或删除权限。
        String ownerType = normalizeOwnerType(rawOwnerType);
        policy(ownerType).requireCanSelectAvatar(ownerId, user);

        Attachment selected = repository.findById(attachmentId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "Attachment not found"));
        if (!ownerType.equals(selected.getOwnerType()) || !ownerId.equals(selected.getOwnerId())) {
            throw new ApiException(ErrorCode.NOT_FOUND, "Attachment not found");
        }
        requireClean(selected);
        // 2026-09-11：不能只看 image/ 前缀。tiff/heic/svg 也是 image/*，但客户端解码不了，
        // 选成头像就是一个永远加载失败的空头像（读取侧本就只放行下面五种）。
        if (!StringUtils.hasText(selected.getContentType())
                || !RENDERABLE_AVATAR_TYPES.contains(
                        selected.getContentType().toLowerCase(Locale.ROOT))) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "Only image attachments can be selected as an avatar");
        }

        repository.findByOwnerTypeAndOwnerIdOrderByCreatedAtAsc(ownerType, ownerId)
                .forEach(candidate -> {
                    if (candidate.isAvatar() && !candidate.getId().equals(selected.getId())) {
                        candidate.setAvatar(false);
                        repository.save(candidate);
                    }
                });
        selected.setAvatar(true);
        repository.save(selected);
        return selected.getStorageKey();
    }

    @Transactional(readOnly = true)
    public AttachmentDownloadResponse downloadGrant(UUID id) {
        requireStorageEnabled();
        AuthUser user = requireStaff();
        require(user, "attachment:download");
        Attachment attachment = repository.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "Attachment not found"));
        requireClean(attachment);
        policy(attachment.getOwnerType()).requireCanView(attachment.getOwnerId(), user);

        StorageService.PresignedDownload grant = storageProviders.require(attachment.getStorageProvider()).presignDownload(
                attachment.getStorageKey(), attachment.getStorageVersion());
        audit.logExplicit(user.getId(), user.getLoginAccount(),
                "attachment_download_grant", "attachments",
                id.toString(), "success");
        return new AttachmentDownloadResponse(grant.url(), grant.expiresAt());
    }

    /**
     * 在线预览的授权入口（与 download-grant 同门槛：attachment:download + owner 策略可读），
     * 返回可延迟打开的原件流；转换与缓存由 {@link AttachmentPreviewService} 负责。
     */
    @Transactional(readOnly = true)
    public PreviewSource openPreviewSource(UUID id) {
        requireStorageEnabled();
        AuthUser user = requireStaff();
        require(user, "attachment:download");
        Attachment attachment = repository.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "Attachment not found"));
        requireClean(attachment);
        policy(attachment.getOwnerType()).requireCanView(attachment.getOwnerId(), user);
        audit.logExplicit(user.getId(), user.getLoginAccount(),
                "attachment_preview", "attachments", id.toString(), "success");
        return new PreviewSource(attachment.getId(), attachment.getOriginalName(),
                normalizeContentType(attachment.getContentType()), attachment.getSizeBytes(),
                attachment.getSha256(), () -> downloadVerifier.open(attachment));
    }

    /** 已授权原件的元数据 + 受限打开器（打开时才占用下载槽位并校验字节）。 */
    public record PreviewSource(UUID id, String originalName, String contentType, long sizeBytes,
                                String sha256, java.util.function.Supplier<InputStream> opener) {
        public InputStream open() {
            return opener.get();
        }
    }

    /**
     * 上传完成后设置/清除分类。分类只是可选标注：不影响对象字节、访问范围或生命周期，
     * 因此不占用删除权限，但走与删除同一条对象授权路径 —— 单据被审核锁定后附件只读，
     * 分类同样改不动。空白值 = 清除分类；服务端只限长度，取值词表由各页面决定。
     */
    @Transactional
    public AttachmentDto setCategory(UUID id, String rawCategory) {
        AuthUser user = requireStaff();
        require(user, "attachment:upload");
        Attachment attachment = repository.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "Attachment not found"));
        requireClean(attachment);
        policy(attachment.getOwnerType()).requireCanManageForUpdate(attachment.getOwnerId(), user);

        String category = normalizeCategory(rawCategory);
        attachment.setCategory(category);
        repository.saveAndFlush(attachment);
        audit.logCommitted(user.getId(), user.getLoginAccount(),
                "attachment_category_set", "attachments", id.toString(),
                category == null ? "cleared" : "success");
        return toDto(attachment);
    }

    private static String normalizeCategory(String category) {
        if (!StringUtils.hasText(category)) {
            return null;
        }
        String trimmed = category.trim();
        if (trimmed.length() > 48) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "Attachment category exceeds 48 characters");
        }
        return trimmed;
    }

    /** Commits deletion intent and returns without coupling the DB transaction to OSS. */
    @Transactional
    public void delete(UUID id) {
        requireStorageEnabled();
        AuthUser user = requireStaff();
        require(user, "attachment:delete");
        Attachment attachment = repository.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "Attachment not found"));
        policy(attachment.getOwnerType()).requireCanManageForUpdate(attachment.getOwnerId(), user);
        if (attachment.getLifecycleState() == AttachmentLifecycleState.DELETED
                || attachment.getLifecycleState() == AttachmentLifecycleState.DELETE_PENDING
                || attachment.getLifecycleState() == AttachmentLifecycleState.DELETE_FAILED) {
            return;
        }
        requireClean(attachment);
        attachment.setLifecycleState(AttachmentLifecycleState.DELETE_PENDING);
        attachment.setDeleteRequestedAt(Instant.now());
        attachment.setDeleteRequestedBy(user.getId());
        attachment.setDeleteFailure(null);
        repository.saveAndFlush(attachment);
        objectOutbox.enqueueFinal(
                attachment.getId(), attachment.getStorageKey(), attachment.getStorageVersion(), attachment.getStorageProvider());
    }

    /** Local-only raw upload, still bound to the signed reservation and hard length. */
    public void storeRaw(String storageKey, String uploadToken, InputStream input,
                         long contentLength, String rawContentType) {
        uploadSafetyGate.requireUploadEnabled();
        AuthUser user = requireStaff();
        require(user, "attachment:upload");
        Grant grant = uploadGrants.verify(uploadToken);
        String contentType = normalizeContentType(rawContentType);
        requireGrantMatches(grant, storageKey, grant.ownerType(), grant.ownerId(), user.getId(),
                grant.originalName(), contentType, contentLength);
        validateUpload(grant.originalName(), contentType, contentLength);
        policy(grant.ownerType()).requireCanManage(grant.ownerId(), user);
        AttachmentUploadSessionStore.UploadSession session = uploadSessions.findByStorageKey(storageKey);
        if (session == null || !session.matches(grant) || !"PENDING".equals(session.status())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "Attachment upload reservation is absent or no longer writable");
        }
        if (repository.existsByStorageKey(storageKey)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "Attachment object is already bound and cannot be overwritten");
        }

        StorageService objectStorage=storageProviders.require(session.storageProvider());
        if (!(objectStorage instanceof BlobStore store)) {
            throw new ApiException(ErrorCode.NOT_FOUND,
                    "Local raw upload is not enabled for this storage provider");
        }
        try {
            store.store(storageKey, input, contentLength, contentType);
        } catch (IllegalStateException e) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "Attachment write failed or the object already exists");
        }
        StoredObject stored = objectStorage.describe(storageKey);
        if (!stored.exists() || stored.size() != contentLength) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "Stored attachment length differs from its signed grant");
        }
    }

    @Transactional(readOnly = true)
    public RawDownload openRaw(String storageKey) {
        AuthUser user = requireStaff();
        require(user, "attachment:download");
        Attachment metadata = repository.findByStorageKey(storageKey)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "Attachment not found"));
        requireClean(metadata);
        policy(metadata.getOwnerType()).requireCanView(metadata.getOwnerId(), user);

        InputStream input = downloadVerifier.open(metadata);
        String fileName = metadata.getOriginalName() != null
                ? metadata.getOriginalName() : storageKey;
        String contentType = metadata.getContentType() != null
                ? metadata.getContentType() : MediaType.APPLICATION_OCTET_STREAM_VALUE;
        // 与 downloadGrant（OSS/通用入口）对等的业务级下载审计：谁在何时取走了哪个附件。
        auditDownloadOrClose(input,user,"attachment_download_raw",metadata.getId());
        return new RawDownload(input, contentType, fileName, metadata.getSizeBytes());
    }

    private void auditDownloadOrClose(InputStream input, AuthUser user, String action, UUID attachmentId) {
        try { audit.logExplicit(user.getId(),user.getLoginAccount(),action,"attachments",attachmentId.toString(),"success"); }
        catch(RuntimeException failure) {
            try { input.close(); } catch(java.io.IOException closeFailure) { failure.addSuppressed(closeFailure); }
            throw failure;
        }
    }

    public record RawDownload(InputStream stream, String contentType, String fileName, long sizeBytes) {
    }

    private void reject(AttachmentUploadSessionStore.UploadSession session,
                        StoredObject stagingObject, String failureCode, ScanResult scan) {
        uploadSessions.reject(
                session.id(), failureCode,
                scan == null ? malwareScanner.provider() : scan.engine(),
                scan == null ? failureCode : scan.signature());
        objectOutbox.enqueueStaging(
                session.id(), session.storageKey(), stagingObject.versionId(), session.storageProvider());
    }

    private AttachmentDto toDto(Attachment attachment) {
        return new AttachmentDto(
                attachment.getId(), attachment.getOwnerType(), attachment.getOwnerId(),
                attachment.getStorageKey(), attachment.getOriginalName(),
                attachment.getContentType(), attachment.getSizeBytes(),
                attachment.getCreatedAt(), attachment.getCreatedBy(), null,
                attachment.getCategory(), attachment.isAvatar());
    }

    private AttachmentOwnerAccessPolicy policy(String rawOwnerType) {
        String ownerType = normalizeOwnerType(rawOwnerType);
        List<AttachmentOwnerAccessPolicy> matches = ownerPolicies.stream()
                .filter(candidate -> ownerType.equalsIgnoreCase(candidate.ownerType()))
                .toList();
        if (matches.size() != 1) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "Unsupported attachment owner type: " + ownerType);
        }
        return matches.getFirst();
    }

    private void requireStorageEnabled() {
        if (!storage.isEnabled()) {
            throw new ApiException(ErrorCode.BUSINESS, "Attachment storage is disabled");
        }
    }

    private static void requireClean(Attachment attachment) {
        if (attachment.getLifecycleState() != AttachmentLifecycleState.CLEAN) {
            throw new ApiException(ErrorCode.NOT_FOUND, "Attachment is not available");
        }
    }

    private void validateUpload(String fileName, String contentType, long size) {
        if (!StringUtils.hasText(fileName)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "Attachment name is required");
        }
        String normalized = normalizeContentType(contentType);
        if (!StringUtils.hasText(normalized)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "Attachment type is required");
        }
        boolean allowed = properties.getAllowedContentTypes().stream()
                .anyMatch(allowedType -> allowedType.equalsIgnoreCase(normalized));
        if (!allowed) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "Unsupported attachment type: " + normalized);
        }
        if (size <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "Attachment size is invalid");
        }
        if (size > properties.getMaxBytes()) {
            throw new ApiException(ErrorCode.PAYLOAD_TOO_LARGE,
                    "Attachment exceeds the limit of " + properties.getMaxBytes() + " bytes");
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
            throw new ApiException(ErrorCode.FORBIDDEN,
                    "Attachment upload grant does not match this request");
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
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "Attachment owner type is required");
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
