package com.uten.imp.config;

import com.uten.imp.config.props.StorageProperties;
import jakarta.annotation.PostConstruct;
import org.springframework.core.env.Environment;
import org.springframework.core.env.Profiles;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

import java.net.URI;

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

        if (!"oss".equalsIgnoreCase(storageProperties.getProvider())) {
            throw new IllegalStateException(
                    "prod/cloud profiles require UTEN_STORAGE_PROVIDER=oss");
        }

        StorageProperties.Oss oss = storageProperties.getOss();
        if (oss == null || !oss.isRequireVersioning()) {
            throw new IllegalStateException(
                    "prod/cloud profiles require UTEN_OSS_REQUIRE_VERSIONING=true");
        }
        requireHttpsEndpoint(oss.getEndpoint());
    }

    private static void requireHttpsEndpoint(String value) {
        if (!StringUtils.hasText(value)) {
            throw new IllegalStateException(
                    "prod/cloud profiles require UTEN_OSS_ENDPOINT to be HTTPS");
        }
        try {
            URI endpoint = URI.create(value.trim());
            if (!"https".equalsIgnoreCase(endpoint.getScheme())
                    || !StringUtils.hasText(endpoint.getHost())
                    || endpoint.getUserInfo() != null) {
                throw new IllegalStateException(
                        "prod/cloud profiles require UTEN_OSS_ENDPOINT to be HTTPS");
            }
        } catch (IllegalArgumentException e) {
            throw new IllegalStateException(
                    "prod/cloud profiles require a valid HTTPS UTEN_OSS_ENDPOINT", e);
        }
    }
}
