package com.uten.imp.features.attachment;

import com.uten.imp.common.storage.StorageService.StoredObject;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.attachment.AttachmentUploadGrantService.Grant;
import com.uten.imp.security.AuthUser;
import lombok.RequiredArgsConstructor;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** Keeps the owner lock and database transaction short after object bytes were inspected. */
@Service
@RequiredArgsConstructor
class AttachmentConfirmTransaction {

    private final AttachmentRepository repository;

    @Transactional
    Attachment persist(Grant grant,
                       AuthUser user,
                       AttachmentOwnerAccessPolicy ownerPolicy,
                       StoredObject object,
                       String persistedContentType,
                       String sha256) {
        ownerPolicy.requireCanManageForUpdate(grant.ownerId(), user);

        Attachment existing = repository.findByStorageKey(grant.storageKey()).orElse(null);
        if (existing != null) {
            if (AttachmentService.sameBinding(existing, grant)
                    && user.getId().equals(existing.getCreatedBy())) {
                return existing;
            }
            throw new ApiException(ErrorCode.CONFLICT,
                    "The uploaded object is already bound and cannot be reused");
        }

        Attachment entity = new Attachment();
        entity.setOwnerType(grant.ownerType());
        entity.setOwnerId(grant.ownerId());
        entity.setStorageKey(grant.storageKey());
        entity.setStorageVersion(object.versionId());
        entity.setStorageEtag(object.eTag());
        entity.setOriginalName(grant.originalName());
        entity.setContentType(persistedContentType);
        entity.setSizeBytes(object.size());
        entity.setSha256(sha256);
        try {
            return repository.saveAndFlush(entity);
        } catch (DataIntegrityViolationException e) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "The uploaded object is already bound and cannot be reused");
        }
    }
}
