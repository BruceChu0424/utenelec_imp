package com.uten.imp.common.storage;

import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

/**
 * 未启用占位后端。provider=disabled 时装配，所有操作抛异常，上传接口报 503。
 * 保证容器始终有一个 StorageService bean，注入不报错。
 */
@Slf4j
@Component
@ConditionalOnProperty(prefix = "uten.storage", name = "provider", havingValue = "disabled")
public class DisabledStorageService implements StorageService {

    public DisabledStorageService() {
        log.warn("StorageService 处于 disabled，附件上传/下载不可用（UTEN_STORAGE_PROVIDER=disabled）");
    }

    private static UnsupportedOperationException unavailable() {
        return new UnsupportedOperationException("附件存储未启用（UTEN_STORAGE_PROVIDER=disabled）");
    }

    @Override
    public PresignedUpload presignUpload(UploadRequest request) {
        throw unavailable();
    }

    @Override
    public StoredObject describe(String storageKey) {
        throw unavailable();
    }

    @Override
    public PresignedDownload presignDownload(String storageKey) {
        throw unavailable();
    }

    @Override
    public void delete(String storageKey) {
        throw unavailable();
    }

    @Override
    public boolean isEnabled() {
        return false;
    }

    @Override
    public String backend() {
        return "disabled";
    }
}
