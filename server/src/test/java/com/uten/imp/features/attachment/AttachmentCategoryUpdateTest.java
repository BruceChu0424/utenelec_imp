package com.uten.imp.features.attachment;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.common.storage.StorageService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.features.attachment.dto.AttachmentDto;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * 上传后设置分类是可选标注：它既不能替代附件功能权限，也不能绕开业务对象的可写判定。
 * 单据审核锁定后 {@code requireCanManageForUpdate} 抛错，分类必须和删除一样改不动。
 */
class AttachmentCategoryUpdateTest {

    private static final String OWNER_TYPE = "SALES_ORDER";

    private final AttachmentRepository repository = mock(AttachmentRepository.class);
    private final SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
    private final AuditService audit = mock(AuditService.class);
    private final RecordingPolicy policy = new RecordingPolicy();
    private final AttachmentService service = new AttachmentService(
            mock(StorageService.class), repository, new StorageProperties(), currentUser,
            List.of(policy), mock(AttachmentUploadGrantService.class), audit,
            mock(AttachmentConfirmTransaction.class), mock(AttachmentUploadSafetyGate.class),
            mock(AttachmentUploadSessionStore.class), mock(AttachmentMalwareScanner.class),
            mock(AttachmentObjectOutboxStore.class), mock(StorageProviderRegistry.class),
            mock(AttachmentDownloadVerifier.class));

    @Test
    void categoryCannotBeSetWithoutTheAttachmentUploadPermission() {
        Attachment stored = signedIn(Set.of("attachment:view", "attachment:download"));

        assertEquals(ErrorCode.FORBIDDEN,
                assertThrows(ApiException.class,
                        () -> service.setCategory(stored.getId(), "合同")).getCode());
        assertThat(policy.updateChecks).isZero();
        verify(repository, never()).saveAndFlush(any());
        verifyNoInteractions(audit);
    }

    @Test
    void lockedDocumentKeepsItsCategoryReadOnly() {
        Attachment stored = signedIn(Set.of("attachment:upload"));
        policy.rejectUpdate = true;

        assertEquals(ErrorCode.CONFLICT,
                assertThrows(ApiException.class,
                        () -> service.setCategory(stored.getId(), "合同")).getCode());
        assertThat(stored.getCategory()).isNull();
        verify(repository, never()).saveAndFlush(any());
        verifyNoInteractions(audit);
    }

    @Test
    void managedDocumentStoresATrimmedCategoryAndAuditsTheChange() {
        AuthUser user = user(Set.of("attachment:upload"));
        Attachment stored = signedIn(user);

        AttachmentDto updated = service.setCategory(stored.getId(), "  合同  ");

        assertThat(updated.category()).isEqualTo("合同");
        assertThat(stored.getCategory()).isEqualTo("合同");
        assertThat(policy.updateChecks).isOne();
        verify(repository).saveAndFlush(stored);
        verify(audit).logCommitted(user.getId(), "seller", "attachment_category_set",
                "attachments", stored.getId().toString(), "success");
    }

    @Test
    void blankValueClearsTheOptionalCategory() {
        AuthUser user = user(Set.of("attachment:upload"));
        Attachment stored = signedIn(user);
        stored.setCategory("图片");

        assertThat(service.setCategory(stored.getId(), "   ").category()).isNull();
        assertThat(stored.getCategory()).isNull();
        verify(audit).logCommitted(user.getId(), "seller", "attachment_category_set",
                "attachments", stored.getId().toString(), "cleared");

        stored.setCategory("图片");
        assertThat(service.setCategory(stored.getId(), null).category()).isNull();
    }

    @Test
    void categoryLongerThanTheColumnIsRejectedBeforeWriting() {
        Attachment stored = signedIn(Set.of("attachment:upload"));

        assertEquals(ErrorCode.VALIDATION_FAILED,
                assertThrows(ApiException.class,
                        () -> service.setCategory(stored.getId(), "分".repeat(49))).getCode());
        verify(repository, never()).saveAndFlush(any());
        verifyNoInteractions(audit);
    }

    @Test
    void quarantinedOrDeletedAttachmentsAreNotCategorizable() {
        Attachment stored = signedIn(Set.of("attachment:upload"));
        stored.setLifecycleState(AttachmentLifecycleState.DELETE_PENDING);

        assertEquals(ErrorCode.NOT_FOUND,
                assertThrows(ApiException.class,
                        () -> service.setCategory(stored.getId(), "合同")).getCode());
        assertThat(policy.updateChecks).isZero();
        verifyNoInteractions(audit);
    }

    private Attachment signedIn(Set<String> permissions) {
        return signedIn(user(permissions));
    }

    private Attachment signedIn(AuthUser user) {
        when(currentUser.get()).thenReturn(Optional.of(user));
        Attachment stored = new Attachment();
        stored.setOwnerType(OWNER_TYPE);
        stored.setOwnerId(UUID.randomUUID());
        stored.setOriginalName("销售合同.pdf");
        stored.setLifecycleState(AttachmentLifecycleState.CLEAN);
        when(repository.findById(stored.getId())).thenReturn(Optional.of(stored));
        return stored;
    }

    private static AuthUser user(Set<String> permissions) {
        UUID id = UUID.randomUUID();
        return new AuthUser(id, UUID.randomUUID(), "seller", Set.of(), permissions,
                false, true, false);
    }

    /** 只记录被问过几次，并按需模拟「已审核 → 不可改」的对象状态判定。 */
    private static final class RecordingPolicy implements AttachmentOwnerAccessPolicy {
        private int updateChecks;
        private boolean rejectUpdate;

        @Override
        public String ownerType() {
            return OWNER_TYPE;
        }

        @Override
        public void requireCanView(UUID ownerId, AuthUser user) {
        }

        @Override
        public void requireCanManage(UUID ownerId, AuthUser user) {
            throw new AssertionError("分类修改必须走 requireCanManageForUpdate（含状态重读）");
        }

        @Override
        public void requireCanManageForUpdate(UUID ownerId, AuthUser user) {
            updateChecks++;
            if (rejectUpdate) {
                throw new ApiException(ErrorCode.CONFLICT, "Document is locked for review");
            }
        }
    }
}
