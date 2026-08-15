package com.uten.imp.features.attachment;

import com.uten.imp.common.storage.StorageService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import jakarta.annotation.PostConstruct;
import lombok.RequiredArgsConstructor;
import org.springframework.core.env.Environment;
import org.springframework.stereotype.Component;

import java.util.Arrays;

@Component
@RequiredArgsConstructor
final class AttachmentUploadSafetyGate {
    private final StorageProperties properties;
    private final StorageService storage;
    private final AttachmentMalwareScanner scanner;
    private final Environment environment;

    @PostConstruct
    void validateConfiguration() {
        if (properties.getMaxBytes() <= 0
                || properties.getMaxPendingPerUser() <= 0
                || properties.getMaxPendingPerOwner() <= 0
                || properties.getMaxPendingBytesPerUser() < properties.getMaxBytes()
                || properties.getMaxPendingBytesPerOwner() < properties.getMaxBytes()) {
            throw new IllegalStateException("Attachment quota configuration is invalid");
        }
        if (!properties.isUploadsEnabled()) {
            return;
        }
        if (!storage.isEnabled() || "disabled".equals(scanner.provider())) {
            throw new IllegalStateException(
                    "Attachment uploads require storage and a malware scanner");
        }
        boolean production = Arrays.stream(environment.getActiveProfiles())
                .anyMatch(profile -> "prod".equals(profile) || "cloud".equals(profile));
        if (production && !"clamav".equals(scanner.provider())) {
            throw new IllegalStateException(
                    "Production attachment uploads require the ClamAV provider");
        }
        if (production && "oss".equalsIgnoreCase(properties.getProvider())
                && !properties.getOss().isRequireVersioning()) {
            throw new IllegalStateException(
                    "Production OSS uploads require split-Bucket versioning verification");
        }
    }

    void requireUploadEnabled() {
        if (!properties.isUploadsEnabled()) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "Attachment upload is disabled pending security acceptance");
        }
        if (!storage.isEnabled() || "disabled".equals(scanner.provider())) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "Attachment scanning is unavailable; upload remains closed");
        }
    }
}
