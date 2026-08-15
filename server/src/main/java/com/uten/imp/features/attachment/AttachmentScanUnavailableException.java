package com.uten.imp.features.attachment;

final class AttachmentScanUnavailableException extends RuntimeException {
    AttachmentScanUnavailableException(String message) {
        super(message);
    }

    AttachmentScanUnavailableException(String message, Throwable cause) {
        super(message, cause);
    }
}
