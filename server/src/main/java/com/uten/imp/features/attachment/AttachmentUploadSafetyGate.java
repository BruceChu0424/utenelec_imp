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
        if ("oss".equals(storage.backend())) {
            throw new IllegalStateException("OSS supports historical reads only; new attachments require internal storage");
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
                    "附件上传功能尚未开放（安全验收未完成），请联系管理员");
        }
        if ("oss".equals(storage.backend())) {
            throw new ApiException(ErrorCode.BUSINESS,"新附件只允许写入内部服务器，OSS仅供历史读取");
        }
        if (!storage.isEnabled() || "disabled".equals(scanner.provider())) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "安全扫描服务暂不可用，暂时不能上传附件，请稍后再试");
        }
    }
}
