package com.uten.imp.features.attachment.dto;

import java.time.Instant;

/** A short-lived, object-authorized download grant issued only on demand. */
public record AttachmentDownloadResponse(String url, Instant expiresAt) {
}
