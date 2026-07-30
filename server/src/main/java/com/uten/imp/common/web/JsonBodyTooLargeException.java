package com.uten.imp.common.web;

/** Internal signal used when an inbound JSON body exceeds the configured cap. */
public final class JsonBodyTooLargeException extends RuntimeException {

    private final int maxBytes;

    public JsonBodyTooLargeException(int maxBytes) {
        super("JSON request body exceeds configured limit");
        this.maxBytes = maxBytes;
    }

    public int getMaxBytes() {
        return maxBytes;
    }
}
