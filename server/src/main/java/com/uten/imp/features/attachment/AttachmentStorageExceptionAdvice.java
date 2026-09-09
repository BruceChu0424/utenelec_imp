package com.uten.imp.features.attachment;

import com.uten.imp.common.storage.StorageResourceUnavailableException;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import java.time.Instant;
import java.util.Map;

@Order(Ordered.HIGHEST_PRECEDENCE)
@RestControllerAdvice
class AttachmentStorageExceptionAdvice {
    @ExceptionHandler(StorageResourceUnavailableException.class)
    ResponseEntity<Map<String, Object>> unavailable(StorageResourceUnavailableException exception) {
        return ResponseEntity.status(503).header("Retry-After", "5")
                .body(Map.of("timestamp", Instant.now().toString(), "status", 503,
                        "code", "ATTACHMENT_STORAGE_BUSY", "message", exception.getMessage()));
    }
}
