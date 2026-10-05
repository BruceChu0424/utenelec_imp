package com.uten.imp.features.attachment;

import com.uten.imp.common.storage.StorageService;

import java.io.InputStream;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Test double around a real storage: every call is delegated; {@link #beforeDelete(int)} runs before
 * each physical delete so a test can slow down, fail or pause the delete loop of the reset.
 */
class DelegatingTestStorage implements StorageService {
    interface Hook { void beforeDelete(int deleteNumber); }

    private final StorageService target;
    private final Hook hook;
    private final AtomicInteger deletes = new AtomicInteger();

    DelegatingTestStorage(StorageService target, Hook hook) {
        this.target = target;
        this.hook = hook;
    }

    int deletes() { return deletes.get(); }

    private void beforeDelete() {
        hook.beforeDelete(deletes.incrementAndGet());
    }

    @Override public PresignedUpload presignUpload(UploadRequest request) { return target.presignUpload(request); }
    @Override public StoredObject describe(String storageKey) { return target.describe(storageKey); }
    @Override public InputStream openForValidation(String storageKey, String versionId) { return target.openForValidation(storageKey, versionId); }
    @Override public InputStream openFinal(String storageKey, String versionId) { return target.openFinal(storageKey, versionId); }
    @Override public StoredObject promoteToFinal(String storageKey, StoredObject stagingObject) { return target.promoteToFinal(storageKey, stagingObject); }
    @Override public PresignedDownload presignDownload(String storageKey, String versionId) { return target.presignDownload(storageKey, versionId); }
    @Override public void delete(String storageKey, String versionId) { beforeDelete(); target.delete(storageKey, versionId); }
    @Override public void deleteStaging(String storageKey, String versionId) { beforeDelete(); target.deleteStaging(storageKey, versionId); }
    @Override public StoredObject inspectObject(ObjectLocation location, String storageKey) { return target.inspectObject(location, storageKey); }
    @Override public List<StoredObjectRef> inventory() { return target.inventory(); }
    @Override public boolean isEnabled() { return target.isEnabled(); }
    @Override public String backend() { return target.backend(); }
}
