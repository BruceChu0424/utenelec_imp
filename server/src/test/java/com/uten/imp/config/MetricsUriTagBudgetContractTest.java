package com.uten.imp.config;

import com.uten.imp.UtenImpApplication;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.config.MeterFilter;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.Test;
import org.springframework.boot.context.config.ConfigDataEnvironmentPostProcessor;
import org.springframework.boot.context.properties.bind.Binder;
import org.springframework.boot.micrometer.metrics.autoconfigure.MetricsProperties;
import org.springframework.context.annotation.ClassPathScanningCandidateComponentProvider;
import org.springframework.context.support.StaticApplicationContext;
import org.springframework.core.env.MapPropertySource;
import org.springframework.core.env.StandardEnvironment;
import org.springframework.core.type.filter.AnnotationTypeFilter;
import org.springframework.stereotype.Controller;
import org.springframework.web.servlet.mvc.method.annotation.RequestMappingHandlerMapping;

import java.nio.file.Path;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class MetricsUriTagBudgetContractTest {
    /** Stable framework paths and failure buckets outside the application controller directory. */
    private static final Set<String> RESERVED_URI_TAGS = Set.of(
            "root", "NOT_FOUND", "REDIRECTION", "UNKNOWN", "none",
            "/error", "/**", "/actuator", "/actuator/health", "/actuator/health/**",
            "/actuator/health/{*path}", "/v3/api-docs", "/v3/api-docs.yaml", "/v3/api-docs/{group}",
            "/swagger-ui.html", "/swagger-ui/**", "/webjars/**");

    private record Catalog(Set<String> paths, int controllers, int instantiatedControllers) {}

    @Test
    void finiteApplicationBudgetCoversTheActualRegisteredRouteCatalogAndFrameworkBuckets() {
        StandardEnvironment environment = repositoryDefaults();
        int budget = configuredBudget(environment);
        Catalog catalog = registeredCatalog(environment);
        Set<String> legitimateTags = legitimateTags(catalog);

        assertThat(catalog.controllers()).isGreaterThan(200);
        assertThat(catalog.instantiatedControllers()).isZero();
        assertThat(budget).isEqualTo(2048);
        assertThat(legitimateTags.size())
                .as("Registered URI patterns plus the explicit framework/failure buckets must fit before release")
                .isLessThanOrEqualTo(budget);
        assertThat(acceptedTagCount(legitimateTags, budget)).isEqualTo(legitimateTags.size());
    }

    @Test
    void thePrevious1024BudgetRejectsLegitimateRoutes() {
        Set<String> legitimateTags = legitimateTags(registeredCatalog(repositoryDefaults()));
        assertThat(legitimateTags.size()).isGreaterThan(1024);
        assertThat(acceptedTagCount(legitimateTags, 1024)).isEqualTo(1024);
    }

    @Test
    void dynamicIdsRemainNormalizedAndUnknownPathsRemainBounded() {
        int budget = configuredBudget(repositoryDefaults());
        var registry = new SimpleMeterRegistry();
        try {
            registry.config().meterFilter(new MetricsConfig().uriNormalizingMeterFilter());
            registry.config().meterFilter(MeterFilter.maximumAllowableTags(
                    "http.server.requests", "uri", budget, MeterFilter.deny()));
            for (int index = 0; index < 20; index++) {
                Counter.builder("http.server.requests").tag("uri", "/api/goods/" + UUID.randomUUID() + "/" + index)
                        .register(registry).increment();
            }
            assertThat(registry.getMeters()).hasSize(1);
            assertThat(registry.getMeters().getFirst().getId().getTag("uri"))
                    .isEqualTo("/api/goods/{id}/{id}");
            for (int index = 0; index < budget + 20; index++) {
                Counter.builder("http.server.requests").tag("uri", "/unknown/probe-" + index)
                        .register(registry).increment();
            }
            assertThat(registry.getMeters()).hasSize(budget);
        } finally {
            registry.close();
        }
    }

    private static StandardEnvironment repositoryDefaults() {
        var environment = new StandardEnvironment();
        // Inspect repository defaults, rather than the operator's local metrics override.
        environment.getPropertySources().remove(StandardEnvironment.SYSTEM_ENVIRONMENT_PROPERTY_SOURCE_NAME);
        environment.getPropertySources().remove(StandardEnvironment.SYSTEM_PROPERTIES_PROPERTY_SOURCE_NAME);
        environment.getPropertySources().addFirst(new MapPropertySource("source-config", Map.of(
                "spring.config.location", Path.of("src/main/resources").toAbsolutePath().toUri().toString())));
        environment.setActiveProfiles("dev");
        ConfigDataEnvironmentPostProcessor.applyTo(environment);
        return environment;
    }

    private static int configuredBudget(StandardEnvironment environment) {
        return Binder.get(environment).bind("management.metrics", MetricsProperties.class)
                .orElseThrow(() -> new IllegalStateException("Metrics repository configuration is missing"))
                .getWeb().getServer().getMaxUriTags();
    }

    private static Catalog registeredCatalog(StandardEnvironment environment) {
        var scanner = new ClassPathScanningCandidateComponentProvider(false, environment);
        scanner.addIncludeFilter(new AnnotationTypeFilter(Controller.class));
        String mainClasses = UtenImpApplication.class.getProtectionDomain().getCodeSource()
                .getLocation().toExternalForm();
        Set<String> controllerNames = new LinkedHashSet<>();
        Set<String> paths = new LinkedHashSet<>();
        int instantiated = 0;
        try (var context = new StaticApplicationContext()) {
            context.setEnvironment(environment);
            for (var definition : scanner.findCandidateComponents("com.uten.imp")) {
                String className = definition.getBeanClassName();
                if (className == null) throw new IllegalStateException("Controller metadata has no class name");
                var resource = UtenImpApplication.class.getClassLoader()
                        .getResource(className.replace('.', '/') + ".class");
                if (resource == null || !resource.toExternalForm().startsWith(mainClasses)) continue;
                definition.setLazyInit(true);
                context.registerBeanDefinition(className, definition);
                controllerNames.add(className);
            }
            context.refresh();
            var mappings = new RequestMappingHandlerMapping();
            mappings.setApplicationContext(context);
            mappings.setEmbeddedValueResolver(environment::resolvePlaceholders);
            mappings.afterPropertiesSet();
            mappings.getHandlerMethods().keySet().forEach(mapping -> paths.addAll(mapping.getPatternValues()));
            for (String name : controllerNames) {
                if (context.getBeanFactory().containsSingleton(name)) instantiated++;
            }
        }
        return new Catalog(Set.copyOf(paths), controllerNames.size(), instantiated);
    }

    private static Set<String> legitimateTags(Catalog catalog) {
        Set<String> tags = new LinkedHashSet<>(catalog.paths());
        tags.addAll(RESERVED_URI_TAGS);
        return Set.copyOf(tags);
    }

    private static int acceptedTagCount(Set<String> tags, int budget) {
        var registry = new SimpleMeterRegistry();
        try {
            registry.config().meterFilter(MeterFilter.maximumAllowableTags(
                    "http.server.requests", "uri", budget, MeterFilter.deny()));
            for (String uri : tags) {
                Counter.builder("http.server.requests").tag("uri", uri).register(registry).increment();
            }
            return registry.getMeters().size();
        } finally {
            registry.close();
        }
    }
}
