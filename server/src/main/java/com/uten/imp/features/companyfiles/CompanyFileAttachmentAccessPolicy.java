package com.uten.imp.features.companyfiles;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;

import org.springframework.context.annotation.Lazy;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/**
 * Generic attachment routes must apply exactly the same current ACL and session-password boundary.
 */
@Component
public class CompanyFileAttachmentAccessPolicy implements AttachmentOwnerAccessPolicy {
    private final CompanyFileService service;

    public CompanyFileAttachmentAccessPolicy(@Lazy CompanyFileService service) {
        this.service = service;
    }

    @Override
    public String ownerType() {
        return CompanyFileService.OWNER_TYPE;
    }

    @Override
    public void requireCanView(UUID id, AuthUser user) {
        service.requireAttachmentView(id, user);
    }

    @Override
    public void requireCanDownload(UUID id, AuthUser user) {
        service.requireAttachmentDownload(id, user);
    }

    @Override
    public void requireCanViewSensitiveOriginal(UUID id, AuthUser user) {
        service.requireAttachmentDownload(id, user);
    }

    @Override
    public void requireCanViewSensitiveOriginalHistory(UUID id, AuthUser user) {
        service.requireAttachmentDownload(id, user);
    }

    @Override
    public void requireCanManage(UUID id, AuthUser user) {
        service.requireAttachmentUpload(id, user, false);
    }

    @Override
    public void requireCanUpload(UUID id, AuthUser user) {
        service.requireAttachmentUpload(id, user, false);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireCanUploadForUpdate(UUID id, AuthUser user) {
        service.requireAttachmentUpload(id, user, true);
    }

    @Override
    public void requireCanManageForUpdate(UUID id, AuthUser user) {
        // Generic category edits must not become a way to replace or delete library originals.
        throw new ApiException(ErrorCode.FORBIDDEN, "请从公司资料库整理文件信息");
    }

    @Override
    public void requireCanDeleteForUpdate(UUID id, AuthUser user) {
        throw new ApiException(ErrorCode.FORBIDDEN, "请从公司资料库移入回收站，原件会保留以便还原");
    }
}
