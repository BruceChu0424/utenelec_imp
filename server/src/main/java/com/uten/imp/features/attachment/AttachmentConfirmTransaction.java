package com.uten.imp.features.attachment;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.storage.StorageService.StoredObject;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.attachment.AttachmentMalwareScanner.ScanResult;
import com.uten.imp.features.attachment.AttachmentUploadGrantService.Grant;
import com.uten.imp.security.AuthUser;
import lombok.RequiredArgsConstructor;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.UUID;

/** Commits the clean metadata, session result and staging-delete intent atomically. */
@Service
@RequiredArgsConstructor
class AttachmentConfirmTransaction {

    private final AttachmentRepository repository;
    private final AttachmentUploadSessionStore sessions;
    private final AttachmentObjectOutboxStore outbox;
    private final JdbcTemplate jdbc;

    @Transactional
    Attachment persist(UUID sessionId,
                       Grant grant,
                       AuthUser user,
                       AttachmentOwnerAccessPolicy ownerPolicy,
                       StoredObject stagingObject,
                       StoredObject finalObject,
                       String persistedContentType,
                       String sha256,
                       ScanResult scan,
                       String category) {
        ownerPolicy.requireCanManageForUpdate(grant.ownerId(), user);
        jdbc.queryForObject(
                "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))::text",
                String.class,
                "attachment-object:" + grant.storageKey());

        Attachment existing = repository.findByStorageKey(grant.storageKey()).orElse(null);
        if (existing != null) {
            if (existing.getLifecycleState() == AttachmentLifecycleState.CLEAN
                    && AttachmentService.sameBinding(existing, grant)
                    && user.getId().equals(existing.getCreatedBy())) {
                return existing;
            }
            throw new ApiException(ErrorCode.CONFLICT,
                    "The uploaded object is already bound and cannot be reused");
        }

        Instant now = Instant.now();
        Attachment entity = new Attachment();
        entity.setOwnerType(grant.ownerType());
        entity.setOwnerId(grant.ownerId());
        entity.setStorageKey(grant.storageKey());
        entity.setStorageVersion(finalObject.versionId());
        entity.setStorageEtag(finalObject.eTag());
        entity.setOriginalName(grant.originalName());
        entity.setContentType(persistedContentType);
        entity.setSizeBytes(finalObject.size());
        entity.setCategory(category);
        entity.setSha256(sha256);
        entity.setLifecycleState(AttachmentLifecycleState.CLEAN);
        entity.setScanEngine(scan.engine());
        entity.setScanSignature(scan.signature());
        entity.setScannedAt(now);
        entity.setPromotedAt(now);
        try {
            Attachment saved = repository.saveAndFlush(entity);
            sessions.completePromotion(
                    sessionId,
                    stagingObject.versionId(), stagingObject.eTag(), sha256,
                    finalObject.versionId(), finalObject.eTag(),
                    scan.engine(), scan.signature());
            // Keep the immutable staging object until the signed POST policy is
            // expired. With overwrite prevention this closes the only replay
            // window between successful confirmation and asynchronous cleanup.
            outbox.enqueueStagingAfter(
                    sessionId, grant.storageKey(), stagingObject.versionId(),
                    grant.expiresAt());
            return saved;
        } catch (DataIntegrityViolationException e) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "The uploaded object is already bound and cannot be reused");
        }
    }
}
