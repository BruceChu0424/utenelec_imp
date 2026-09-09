package com.uten.imp.common.storage;

/** Bounded storage intake is temporarily unavailable; callers may retry without changing the grant. */
public final class StorageResourceUnavailableException extends RuntimeException {
    public StorageResourceUnavailableException(String message) { super(message); }
}
