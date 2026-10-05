package com.uten.imp.common.storage;

/**
 * Something occupies one exact object location but it is not an object this system wrote, or it
 * cannot be read. Never means "absent" and never means "storage root unavailable".
 */
public final class StorageObjectProblem extends IllegalStateException {
    public enum Kind { NOT_REGULAR_FILE, UNRECOGNIZED_HEADER, ACCESS_DENIED, IO_ERROR }

    private final Kind kind;

    public StorageObjectProblem(Kind kind, String message, Throwable cause) {
        super(message, cause);
        this.kind = kind;
    }

    public Kind kind() { return kind; }
}
