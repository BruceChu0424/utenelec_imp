package com.uten.imp.features.attachment;

import com.uten.imp.application.port.*;
import com.uten.imp.application.port.AttachmentLinkedEvidencePort.Frozen;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.test.util.ReflectionTestUtils;
import java.time.Instant;
import java.util.*;
import java.util.stream.Stream;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class AttachmentLinkedEvidenceTest {
    AttachmentRepository repository=mock(AttachmentRepository.class);
    @SuppressWarnings("unchecked") ObjectProvider<AttachmentLinkedEvidencePort> providers=mock(ObjectProvider.class);
    AttachmentLinkedEvidencePort source=mock(AttachmentLinkedEvidencePort.class);
    AttachmentOwnerAccessPolicy original=mock(AttachmentOwnerAccessPolicy.class),target=mock(AttachmentOwnerAccessPolicy.class);
    SecurityContextCurrentUser current=mock(SecurityContextCurrentUser.class);
    AuthUser user=mock(AuthUser.class);
    com.uten.imp.common.storage.StorageService storage=mock(com.uten.imp.common.storage.StorageService.class);
    UUID id=UUID.randomUUID(),origin=UUID.randomUUID(),nativeId=UUID.randomUUID();
    String sha="a".repeat(64);
    Attachment row;
    AttachmentLinkedEvidenceSupport support;
    AttachmentService service;

    @BeforeEach void setup(){
        row=new Attachment();ReflectionTestUtils.setField(row,"id",id);row.setOwnerType("FINANCE_APPLICATION");row.setOwnerId(origin);
        row.setOriginalName("original.pdf");row.setSha256(sha);row.setLifecycleState(AttachmentLifecycleState.CLEAN);
        row.setContentType("application/pdf");row.setStorageKey("private/original.pdf");row.setSizeBytes(10L);
        when(providers.orderedStream()).thenAnswer(call->Stream.of(source));
        when(source.linkedEvidence("BUSINESS_APPLICATION",nativeId)).thenReturn(List.of(ref()));
        when(repository.findAllById(any())).thenReturn(List.of(row));when(repository.findById(id)).thenReturn(Optional.of(row));
        when(source.readableOriginal(id,user)).thenReturn(Optional.of(ref()));
        when(current.get()).thenReturn(Optional.of(user));when(user.getId()).thenReturn(UUID.randomUUID());when(user.getEmployeeId()).thenReturn(UUID.randomUUID());
        when(user.getPermissions()).thenReturn(Set.of("attachment:view","attachment:download","attachment:delete","attachment:upload"));
        when(original.ownerType()).thenReturn("FINANCE_APPLICATION");when(target.ownerType()).thenReturn("BUSINESS_APPLICATION");when(storage.isEnabled()).thenReturn(true);
        support=new AttachmentLinkedEvidenceSupport(repository,providers);
        service=new AttachmentService(storage,repository,new com.uten.imp.config.props.StorageProperties(),current,List.of(original,target),
                mock(AttachmentUploadGrantService.class),mock(com.uten.imp.audit.AuditService.class),mock(AttachmentConfirmTransaction.class),
                mock(AttachmentUploadSafetyGate.class),mock(AttachmentUploadSessionStore.class),mock(com.uten.imp.common.files.malware.MalwareScanner.class),
                mock(AttachmentObjectOutboxStore.class),mock(com.uten.imp.common.storage.StorageProviderRegistry.class),mock(AttachmentDownloadVerifier.class),mock(com.uten.imp.audit.AuditActorDirectory.class));
        ReflectionTestUtils.setField(service,"linkedEvidence",support);
    }
    Frozen ref(){return new Frozen(id,"FINANCE_APPLICATION",origin,sha,"original.pdf");}

    @Test void frozenSetUsesTheExactOwnerHashAndCurrentLifecycle(){
        assertTrue(support.ready(List.of()));assertTrue(support.ready(List.of(ref())));
        assertFalse(support.ready(List.of(new Frozen(id,"FINANCE_APPLICATION",UUID.randomUUID(),sha,"original.pdf"))));
        row.setSha256("b".repeat(64));assertFalse(support.ready(List.of(ref())));row.setSha256(sha);
        row.setDeleteRequestedAt(Instant.now());assertFalse(support.ready(List.of(ref())));row.setDeleteRequestedAt(null);
        row.setLifecycleState(AttachmentLifecycleState.RETAINED_HISTORY);assertFalse(support.ready(List.of(ref())));
        row.setLifecycleState(AttachmentLifecycleState.LEGACY_UNVERIFIED);assertFalse(support.ready(List.of(ref())));
    }
    @Test void missingAndConflictingFrozenReferencesNeverBecomeReady(){
        when(repository.findAllById(any())).thenReturn(List.of());assertFalse(support.ready(List.of(ref())));
        assertFalse(support.ready(List.of(new Frozen(id,"FINANCE_APPLICATION",origin,null,"original.pdf"))));
        assertFalse(support.ready(null));
        when(repository.findAllById(any())).thenReturn(List.of(row));
        assertFalse(support.ready(List.of(ref(),new Frozen(id,"FINANCE_APPLICATION",origin,"b".repeat(64),"original.pdf"))));
    }
    @Test void linkedListingChecksNativeOwnerAndReturnsOnlyFrozenReadOnlyIds(){
        var visible=service.listLinkedVisible("BUSINESS_APPLICATION",nativeId);
        assertEquals(List.of(id),visible.stream().map(AttachmentAccessPort.AttachmentView::id).toList());assertTrue(visible.getFirst().historyReadOnly());
        verify(target).requireCanView(nativeId,user);verify(repository,never()).findByOwnerTypeAndOwnerIdAndLifecycleStateOrderByCreatedAtAsc("FINANCE_APPLICATION",origin,AttachmentLifecycleState.CLEAN);
        doThrow(new ApiException(ErrorCode.FORBIDDEN)).when(target).requireCanView(nativeId,user);
        assertThrows(ApiException.class,()->service.listLinkedVisible("BUSINESS_APPLICATION",nativeId));
    }
    @Test void previewFallbackHasCurrentPermissionAndExactFrozenBytes(){
        doThrow(new ApiException(ErrorCode.FORBIDDEN)).when(original).requireCanDownload(origin,user);
        assertEquals(id,service.openPreviewSource(id).id());
        row.setSha256("b".repeat(64));assertThrows(ApiException.class,()->service.openPreviewSource(id));row.setSha256(sha);
        when(source.readableOriginal(id,user)).thenReturn(Optional.empty());assertThrows(ApiException.class,()->service.openPreviewSource(id));
    }
    @Test void referenceDoesNotGrantGlobalDownloadOrExposeAnUnavailableOriginal(){
        doThrow(new ApiException(ErrorCode.FORBIDDEN)).when(original).requireCanDownload(origin,user);
        when(user.getPermissions()).thenReturn(Set.of("attachment:view"));assertThrows(ApiException.class,()->service.openPreviewSource(id));
        when(user.getPermissions()).thenReturn(Set.of("attachment:download"));row.setDeleteRequestedAt(Instant.now());
        assertThrows(ApiException.class,()->service.openPreviewSource(id));
    }
    @Test void originalOwnerStateErrorsDoNotBecomeReaderBypasses(){
        doThrow(new ApiException(ErrorCode.CONFLICT)).when(original).requireCanDownload(origin,user);
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->service.openPreviewSource(id)).getCode());
    }
    @Test void frozenOriginalCannotBeDeletedOrRecategorizedAfterOwnerLock(){
        when(source.immutableOriginal(id)).thenReturn(true);
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->service.delete(id)).getCode());
        var order=inOrder(original,source);order.verify(original).requireCanDeleteForUpdate(origin,user);order.verify(source).immutableOriginal(id);
        assertThrows(ApiException.class,()->service.setCategory(id,"updated"));
        verify(repository,never()).saveAndFlush(any());assertEquals(AttachmentLifecycleState.CLEAN,row.getLifecycleState());assertNull(row.getDeleteRequestedAt());
    }
    @Test void evidenceUnionsDirectAndExactLinkedRowsWithoutDuplicatingIds(){
        when(source.linkedEvidence("FINANCE_APPLICATION",origin)).thenReturn(List.of(ref()));
        when(repository.findByOwnerTypeAndOwnerIdAndLifecycleStateOrderByCreatedAtAsc("FINANCE_APPLICATION",origin,AttachmentLifecycleState.CLEAN)).thenReturn(List.of(row));
        var adapter=new AttachmentEvidenceAdapter(repository);ReflectionTestUtils.setField(adapter,"linked",support);
        assertEquals(List.of(id),adapter.cleanEvidence("FINANCE_APPLICATION",origin).stream().map(AttachmentEvidencePort.Evidence::id).toList());
        row.setLifecycleState(AttachmentLifecycleState.RETAINED_HISTORY);
        when(repository.findByOwnerTypeAndOwnerIdAndLifecycleStateOrderByCreatedAtAsc("FINANCE_APPLICATION",origin,AttachmentLifecycleState.CLEAN)).thenReturn(List.of());
        assertTrue(adapter.cleanEvidence("FINANCE_APPLICATION",origin).isEmpty());assertFalse(adapter.frozenEvidenceReady(List.of(ref())));
    }
}
