package com.uten.imp.config;

import com.uten.imp.config.props.StorageProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.mock.env.MockEnvironment;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;

class ProductionStorageSafetyGateTest {

    @org.junit.jupiter.api.io.TempDir java.nio.file.Path directory;

    @ParameterizedTest
    @ValueSource(strings={"prod","cloud"})
    void acceptsExplicitInternalStorageWithoutPretendingItIsTheDevProvider(String profile) {
        var properties=new StorageProperties();properties.setProvider("internal");
        properties.getInternal().setRoot(directory.toString());
        assertDoesNotThrow(()->gate(profile,properties).validate());
        properties.getInternal().setRoot("relative/data");
        assertThrows(IllegalStateException.class,()->gate(profile,properties).validate());
        properties.getInternal().setRoot(directory.toString());properties.getInternal().setMinFreeBytes(0);
        assertThrows(IllegalStateException.class,()->gate(profile,properties).validate());
    }

    @ParameterizedTest
    @ValueSource(strings = {"prod", "cloud"})
    void productionProfilesRejectOssEvenWithSafeVersioning(String activeProfile) {
        StorageProperties properties = safeOssProperties();

        assertThrows(IllegalStateException.class, () -> gate(activeProfile, properties).validate());
    }

    @ParameterizedTest
    @ValueSource(strings = {"prod", "cloud"})
    void productionProfilesRejectNonOssProvider(String activeProfile) {
        StorageProperties properties = safeOssProperties();
        properties.setProvider("local");

        assertThrows(IllegalStateException.class,
                () -> gate(activeProfile, properties).validate());
    }

    @Test
    void productionProfileRejectsDisabledVersioningGate() {
        StorageProperties properties = safeOssProperties();
        properties.getOss().setRequireVersioning(false);

        assertThrows(IllegalStateException.class,
                () -> gate("prod", properties).validate());
    }

    @ParameterizedTest
    @NullAndEmptySource
    @ValueSource(strings = {
            "http://oss-cn-hangzhou.aliyuncs.com",
            "oss-cn-hangzhou.aliyuncs.com",
            "https://user@oss-cn-hangzhou.aliyuncs.com"
    })
    void cloudProfileRejectsUnsafeEndpoint(String endpoint) {
        StorageProperties properties = safeOssProperties();
        properties.getOss().setEndpoint(endpoint);

        assertThrows(IllegalStateException.class,
                () -> gate("cloud", properties).validate());
    }

    @Test
    void anyProductionProfileAmongActiveProfilesEnablesTheGate() {
        StorageProperties properties = safeOssProperties();
        properties.setProvider("local");
        MockEnvironment environment = new MockEnvironment();
        environment.setActiveProfiles("dev", "cloud");

        assertThrows(IllegalStateException.class,
                () -> new ProductionStorageSafetyGate(environment, properties).validate());
    }

    @ParameterizedTest
    @ValueSource(strings = {"dev", "test", "local"})
    void nonProductionProfilesRemainUnrestricted(String activeProfile) {
        StorageProperties properties = new StorageProperties();
        properties.setProvider("local");
        properties.getOss().setEndpoint("http://localhost:9000");
        properties.getOss().setRequireVersioning(false);

        assertDoesNotThrow(() -> gate(activeProfile, properties).validate());
    }

    @Test
    void noActiveProfileRemainsUnrestricted() {
        StorageProperties properties = new StorageProperties();

        assertDoesNotThrow(() -> new ProductionStorageSafetyGate(
                new MockEnvironment(), properties).validate());
    }

    private static ProductionStorageSafetyGate gate(
            String activeProfile,
            StorageProperties properties) {
        MockEnvironment environment = new MockEnvironment();
        environment.setActiveProfiles(activeProfile);
        return new ProductionStorageSafetyGate(environment, properties);
    }

    private static StorageProperties safeOssProperties() {
        StorageProperties properties = new StorageProperties();
        properties.setProvider("oss");
        properties.getOss().setEndpoint("https://oss-cn-hangzhou.aliyuncs.com");
        properties.getOss().setRequireVersioning(true);
        return properties;
    }
}
