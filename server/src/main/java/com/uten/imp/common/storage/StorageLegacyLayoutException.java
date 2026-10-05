package com.uten.imp.common.storage;

/**
 * A local final object is missing from {@code final/} while a flat historical file with the same
 * name still sits in the storage root. Existing callers keep treating it as "storage unavailable";
 * the test-data reset reports it as its own reason.
 */
public final class StorageLegacyLayoutException extends StorageResourceUnavailableException {
    public StorageLegacyLayoutException(String message) { super(message); }
}
