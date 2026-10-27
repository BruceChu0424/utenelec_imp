package com.uten.imp.testsupport;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.YamlPropertiesFactoryBean;
import org.springframework.context.ApplicationContextInitializer;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.Environment;
import org.springframework.core.env.MapPropertySource;
import org.springframework.core.env.PropertiesPropertySource;
import org.springframework.core.io.ClassPathResource;
import org.springframework.mock.env.MockEnvironment;
import org.springframework.test.context.ContextConfiguration;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.context.junit.jupiter.SpringExtension;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;
import java.util.Properties;
import java.util.function.Supplier;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;

/** No database is created: exercise the real dynamic-property and dev-profile resolution paths. */
@ExtendWith(SpringExtension.class)
@ContextConfiguration(classes = FixtureDatabasePropertiesTest.FixtureOnlyConfiguration.class,
        initializers = FixtureDatabasePropertiesTest.RealDevProperties.class)
@TestPropertySource(properties = {
        "UTEN_DEV_MIGRATOR_DB_USER=unrelated_developer_migrator",
        "UTEN_DEV_MIGRATOR_DB_PASSWORD=developer-test-only"
})
class FixtureDatabasePropertiesTest {
    private static final String URL = "jdbc:postgresql://fixture.invalid:5432/private_fixture";
    private static final String USER = "private_fixture_role";
    private static final String PASSWORD = "fixture-test-only";

    @Configuration(proxyBeanMethods = false)
    static class FixtureOnlyConfiguration { }

    public static class RealDevProperties implements ApplicationContextInitializer<ConfigurableApplicationContext> {
        @Override public void initialize(ConfigurableApplicationContext context) {
            context.getEnvironment().getPropertySources().addLast(
                    new PropertiesPropertySource("actual-development-profile", devProperties()));
        }
    }

    @DynamicPropertySource
    static void fixture(DynamicPropertyRegistry registry) {
        FixtureDatabaseProperties.bindSameRole(registry, () -> URL, () -> USER, () -> PASSWORD);
    }

    @Autowired Environment environment;

    @Test void dataSourceOnlyBindingLeavesTheActualDevMigratorOverrideUnrelatedToTheFixture() {
        var original = new MockEnvironment()
                .withProperty("UTEN_DEV_MIGRATOR_DB_USER", "unrelated_developer_migrator")
                .withProperty("UTEN_DEV_MIGRATOR_DB_PASSWORD", "developer-test-only");
        original.getPropertySources().addLast(new PropertiesPropertySource("actual-development-profile", devProperties()));
        original.getPropertySources().addFirst(new MapPropertySource("old-datasource-only-fixture", Map.of(
                "spring.datasource.url", URL,
                "spring.datasource.username", USER,
                "spring.datasource.password", PASSWORD)));
        assertEquals(USER, original.getProperty("spring.datasource.username"));
        assertEquals("unrelated_developer_migrator", original.getProperty("spring.flyway.user"));
        assertEquals("developer-test-only", original.getProperty("spring.flyway.password"));
        assertNotEquals(original.getProperty("spring.datasource.username"), original.getProperty("spring.flyway.user"));
    }

    @Test void actualDynamicRegistryKeepsBothConnectionDestinationsAndCredentialsInsideThePrivateFixture() {
        assertEquals("unrelated_developer_migrator", environment.getProperty("UTEN_DEV_MIGRATOR_DB_USER"));
        assertEquals(URL, environment.getProperty("spring.datasource.url"));
        assertEquals(USER, environment.getProperty("spring.datasource.username"));
        assertEquals(PASSWORD, environment.getProperty("spring.datasource.password"));
        assertEquals(URL, environment.getProperty("spring.flyway.url"));
        assertEquals(USER, environment.getProperty("spring.flyway.user"));
        assertEquals(PASSWORD, environment.getProperty("spring.flyway.password"));
    }

    @Test void replacingTheSharedHarnessAlsoReplacesEveryFlywayDestinationAndCredential() {
        Map<String, Supplier<?>> registered = new LinkedHashMap<>();
        DynamicPropertyRegistry registry = registered::put;
        FixtureDatabaseProperties.bindSameRole(registry,
                () -> "jdbc:postgresql://shared.invalid:5432/shared_fixture", () -> "shared_role", () -> "shared-test-only");
        FixtureDatabaseProperties.bindSameRole(registry, () -> URL, () -> USER, () -> PASSWORD);
        assertEquals(6, registered.size());
        assertEquals(URL, registered.get("spring.datasource.url").get());
        assertEquals(USER, registered.get("spring.datasource.username").get());
        assertEquals(PASSWORD, registered.get("spring.datasource.password").get());
        assertEquals(URL, registered.get("spring.flyway.url").get());
        assertEquals(USER, registered.get("spring.flyway.user").get());
        assertEquals(PASSWORD, registered.get("spring.flyway.password").get());
    }

    private static Properties devProperties() {
        var yaml = new YamlPropertiesFactoryBean();
        yaml.setResources(new ClassPathResource("application-dev.yml"));
        return Objects.requireNonNull(yaml.getObject(), "Actual dev profile must be available");
    }
}
