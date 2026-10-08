package com.uten.imp.common.storage;

import org.junit.jupiter.api.Test;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import java.time.Instant;
import java.util.Map;
import static org.mockito.Mockito.*;

class ImmutableDocumentStoreTest {
    @Test void uncertainCommitRetainsFinalObjectUntilReferenceReconciliation() {
        var storage = setup();
        TransactionSynchronizationManager.initSynchronization();
        try {
            new ImmutableDocumentStore(storage, mock(StorageProviderRegistry.class), com.uten.imp.common.files.malware.DocumentSafetyTestSupport.scanning()).save("GOODS_COST_IMPORT", "source.xlsx", "application/octet-stream", new byte[]{1});
            TransactionSynchronizationManager.getSynchronizations().forEach(s -> s.afterCompletion(TransactionSynchronization.STATUS_UNKNOWN));
            verify(storage, never()).delete(anyString(), any());
            verify(storage, never()).deleteStaging(anyString(), any());
        } finally { TransactionSynchronizationManager.clearSynchronization(); }
    }
    @Test void knownRollbackDeletesOnlyTheVersionCreatedByThisAttempt() {
        var storage = setup();
        TransactionSynchronizationManager.initSynchronization();
        try {
            new ImmutableDocumentStore(storage, mock(StorageProviderRegistry.class), com.uten.imp.common.files.malware.DocumentSafetyTestSupport.scanning()).save("GOODS_COST_IMPORT", "source.xlsx", "application/octet-stream", new byte[]{1});
            TransactionSynchronizationManager.getSynchronizations().forEach(s -> s.afterCompletion(TransactionSynchronization.STATUS_ROLLED_BACK));
            verify(storage).delete("object-key", "version-1");
            verify(storage).deleteStaging("object-key", "version-1");
        } finally { TransactionSynchronizationManager.clearSynchronization(); }
    }
    private static StorageService setup() {
        StorageService storage = mock(StorageService.class, withSettings().extraInterfaces(BlobStore.class));
        when(storage.isEnabled()).thenReturn(true); when(storage.backend()).thenReturn("internal");
        when(storage.presignUpload(any())).thenReturn(new StorageService.PresignedUpload("object-key", "", "PUT", Map.of(), Map.of(), Instant.EPOCH));
        var staged = new StorageService.StoredObject(true, 1, "application/octet-stream", "staging", "etag");
        when(storage.describe("object-key")).thenReturn(staged);
        when(storage.promoteToFinal("object-key", staged)).thenReturn(new StorageService.StoredObject(true, 1, "application/octet-stream", "version-1", "etag"));
        return storage;
    }
}
