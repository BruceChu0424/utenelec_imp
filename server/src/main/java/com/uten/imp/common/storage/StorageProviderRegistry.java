package com.uten.imp.common.storage;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import jakarta.annotation.PreDestroy;
import org.springframework.stereotype.Component;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;

/** Dispatches by the object's persisted provider, never by a version/key guess. */
@Component
public class StorageProviderRegistry {
    private final StorageService active;
    private final StorageProperties properties;
    private final Map<String,StorageService> historical = new HashMap<>();

    public StorageProviderRegistry(StorageService active,StorageProperties properties) {
        this.active=active;this.properties=properties;
    }

    public StorageService require(String provider) {
        if (provider==null || "legacy_unknown".equals(provider)
                || !java.util.Set.of("internal","oss","local").contains(provider))
            throw new ApiException(ErrorCode.CONFLICT,"历史附件存储来源尚未核定，暂不能读取或删除");
        if (provider.equals(active.backend())) return active;
        synchronized(historical) { return historical.computeIfAbsent(provider,this::openHistorical); }
    }

    private StorageService openHistorical(String provider) {
        try {
            return switch(provider) {
                case "oss" -> OssStorageService.legacyReader(properties);
                case "internal" -> {
                    var storage=new InternalStorageService(properties);storage.init();yield storage;
                }
                case "local" -> {
                    Path root=Path.of(properties.getLocalDir());
                    if (!root.isAbsolute() || !Files.isDirectory(root.resolve("staging"))
                            || !Files.isDirectory(root.resolve("final")))
                        throw new ApiException(ErrorCode.CONFLICT,"历史本地附件目录未明确配置");
                    var storage=new LocalDiskStorageService(properties);storage.init();yield storage;
                }
                default -> throw new ApiException(ErrorCode.CONFLICT,"附件存储来源无法识别");
            };
        } catch(IOException error) { throw new IllegalStateException("Historical attachment backend is unavailable",error); }
    }

    @PreDestroy void close() {
        synchronized(historical) {
            historical.values().stream().filter(OssStorageService.class::isInstance)
                    .map(OssStorageService.class::cast).forEach(OssStorageService::shutdown);
        }
    }
}
