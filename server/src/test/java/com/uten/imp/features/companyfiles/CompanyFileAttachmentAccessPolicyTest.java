package com.uten.imp.features.companyfiles;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;

import org.junit.jupiter.api.Test;

import java.util.UUID;

class CompanyFileAttachmentAccessPolicyTest {
    @Test
    void everyGenericRouteDispatchesItsOwnCurrentLibraryGateAndCannotDeleteOriginals() {
        CompanyFileService service = mock(CompanyFileService.class);
        var policy = new CompanyFileAttachmentAccessPolicy(service);
        UUID id = UUID.randomUUID();
        AuthUser actor = mock(AuthUser.class);
        policy.requireCanView(id, actor);
        verify(service).requireAttachmentView(id, actor);
        policy.requireCanDownload(id, actor);
        verify(service).requireAttachmentDownload(id, actor);
        policy.requireCanUpload(id, actor);
        verify(service).requireAttachmentUpload(id, actor, false);
        policy.requireCanUploadForUpdate(id, actor);
        verify(service).requireAttachmentUpload(id, actor, true);
        assertThatThrownBy(() -> policy.requireCanDeleteForUpdate(id, actor))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> policy.requireCanManageForUpdate(id, actor))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void legacyOwnersKeepTheirExistingViewManageAndLockedUpdateContracts() {
        final int[] calls = {0, 0, 0};
        AttachmentOwnerAccessPolicy owner =
                new AttachmentOwnerAccessPolicy() {
                    @Override
                    public String ownerType() {
                        return "TEST";
                    }

                    @Override
                    public void requireCanView(UUID id, AuthUser user) {
                        calls[0]++;
                    }

                    @Override
                    public void requireCanManage(UUID id, AuthUser user) {
                        calls[1]++;
                    }

                    @Override
                    public void requireCanManageForUpdate(UUID id, AuthUser user) {
                        calls[2]++;
                    }
                };
        UUID id = UUID.randomUUID();
        owner.requireCanDownload(id, null);
        owner.requireCanUpload(id, null);
        owner.requireCanUploadForUpdate(id, null);
        owner.requireCanDeleteForUpdate(id, null);
        assertThat(calls).containsExactly(1, 1, 2);
    }
}
