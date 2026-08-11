package com.uten.imp.common.storage;

import com.uten.imp.config.props.StorageProperties;
import jakarta.annotation.PostConstruct;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.time.Instant;
import java.util.Map;

/**
 * 本地磁盘存储后端（开发与本地测试默认）。provider=local 或缺省时装配。
 *
 * <p>预签名 URL 语义对本后端退化为指向应用自身的原始字节端点
 * {@code /api/attachments/raw/{storageKey}}（PUT 上传 / GET 下载），由 {@code AttachmentController}
 * 经 {@link BlobStore} 读写磁盘。客户端上传/下载流程与 OSS 后端一致。
 */
@Slf4j
@Component
@RequiredArgsConstructor
@ConditionalOnProperty(prefix = "uten.storage", name = "provider",
        havingValue = "local", matchIfMissing = true)
public class LocalDiskStorageService implements StorageService, BlobStore {

    // ApiClient 的 baseUrl 已以 /api 结尾；返回的相对端点必须以 / 开头，
    // 否则 Dio 会拼成 /apiattachments/raw/...。
    private static final String RAW_PATH = "/attachments/raw/";

    private final StorageProperties properties;
    private Path root;

    @PostConstruct
    void init() throws IOException {
        root = Paths.get(properties.getLocalDir()).toAbsolutePath().normalize();
        Files.createDirectories(root);
        log.info("LocalDiskStorageService 已启用，附件目录 {}", root);
    }

    @Override
    public PresignedUpload presignUpload(UploadRequest request) {
        String key = StorageService.generateStorageKey(request.fileName());
        Instant expiry = Instant.now().plusSeconds(properties.getPresignedExpirySeconds());
        return new PresignedUpload(
                key,
                RAW_PATH + key,
                "PUT",
                Map.of("Content-Type", request.contentType() == null
                        ? "application/octet-stream" : request.contentType()),
                expiry);
    }

    @Override
    public StoredObject describe(String storageKey) {
        Path target = resolve(storageKey);
        if (!Files.isRegularFile(target)) {
            return new StoredObject(false, 0, null, null, null);
        }
        try {
            return new StoredObject(true, Files.size(target), null, null, null);
        } catch (IOException e) {
            return new StoredObject(false, 0, null, null, null);
        }
    }

    @Override
    public InputStream openForValidation(String storageKey, String versionId) {
        return read(storageKey);
    }

    @Override
    public PresignedDownload presignDownload(String storageKey, String versionId) {
        return new PresignedDownload(
                RAW_PATH + storageKey,
                Instant.now().plusSeconds(properties.getPresignedExpirySeconds()));
    }

    @Override
    public void delete(String storageKey, String versionId) {
        Path target = resolve(storageKey);
        try {
            Files.deleteIfExists(target);
        } catch (IOException e) {
            log.warn("本地附件删除失败 key={} type={}", storageKey, e.getClass().getSimpleName());
            throw new IllegalStateException("删除本地附件失败", e);
        }
    }

    @Override
    public void store(String storageKey, InputStream in, long contentLength, String contentType) {
        if (contentLength <= 0) {
            throw new IllegalArgumentException("附件 Content-Length 必须大于 0");
        }
        Path target = resolve(storageKey);
        Path temporary = null;
        try {
            Files.createDirectories(target.getParent());
            temporary = Files.createTempFile(root, "upload-", ".part");
            long copied = Files.copy(in, temporary, StandardCopyOption.REPLACE_EXISTING);
            if (copied != contentLength) {
                throw new IllegalStateException("附件实际字节数与 Content-Length 不一致");
            }
            // 默认 move 在目标已存在时失败：storageKey 是一次性能力，绝不覆盖对象。
            Files.move(temporary, target);
        } catch (IOException e) {
            throw new IllegalStateException("写入本地附件失败: " + storageKey, e);
        } finally {
            if (temporary != null) {
                try {
                    Files.deleteIfExists(temporary);
                } catch (IOException cleanupFailure) {
                    log.warn("清理附件临时文件失败 type={}", cleanupFailure.getClass().getSimpleName());
                }
            }
        }
    }

    @Override
    public InputStream read(String storageKey) {
        try {
            return Files.newInputStream(resolve(storageKey));
        } catch (IOException e) {
            throw new IllegalStateException("读取本地附件失败: " + storageKey, e);
        }
    }

    @Override
    public boolean isEnabled() {
        return true;
    }

    @Override
    public String backend() {
        return "local";
    }

    private Path resolve(String storageKey) {
        Path target = root.resolve(storageKey).normalize();
        if (!target.startsWith(root)) {
            // storageKey 受 DB 约束 [A-Za-z0-9._-]+，正常不会触发；防御路径穿越。
            throw new IllegalArgumentException("非法 storageKey: " + storageKey);
        }
        return target;
    }
}
