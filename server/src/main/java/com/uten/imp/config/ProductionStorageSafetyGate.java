package com.uten.imp.config;

import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.common.storage.InternalStorageService;
import jakarta.annotation.PostConstruct;
import org.springframework.core.env.Environment;
import org.springframework.core.env.Profiles;
import org.springframework.stereotype.Component;


/**
 * Fails application startup when a production-like profile weakens attachment storage safety.
 */
@Component
public class ProductionStorageSafetyGate {

    private static final Profiles PRODUCTION_PROFILES = Profiles.of("prod", "cloud");

    private final Environment environment;
    private final StorageProperties storageProperties;

    public ProductionStorageSafetyGate(
            Environment environment,
            StorageProperties storageProperties) {
        this.environment = environment;
        this.storageProperties = storageProperties;
    }

    @PostConstruct
    void validate() {
        if (!environment.acceptsProfiles(PRODUCTION_PROFILES)) {
            return;
        }

        if ("internal".equalsIgnoreCase(storageProperties.getProvider())) {
            InternalStorageService.validateConfiguration(storageProperties);
            // The provider separately proves real-directory fsync and create-only
            // publication at startup; local/dev storage is never this capability.
            if (storageProperties.getInternal().getMinFreeBytes() < 268435456L)
                throw new IllegalStateException("Production internal storage requires at least 256 MiB free-space reserve");
            return;
        }
        throw new IllegalStateException("prod/cloud profiles require UTEN_STORAGE_PROVIDER=internal; OSS is historical read-only");
    }
}
