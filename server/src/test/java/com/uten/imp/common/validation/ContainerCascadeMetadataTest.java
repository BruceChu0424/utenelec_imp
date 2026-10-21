package com.uten.imp.common.validation;

import ch.qos.logback.classic.Logger;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.read.ListAppender;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.org.employee.dto.OnboardingRequest;
import com.uten.imp.features.org.employee.dto.UpdateEmployeeRequest;
import jakarta.validation.Valid;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import jakarta.validation.metadata.ContainerElementTypeDescriptor;
import org.junit.jupiter.api.Test;
import org.slf4j.LoggerFactory;

import java.lang.reflect.AnnotatedParameterizedType;
import java.lang.reflect.AnnotatedType;
import java.lang.reflect.Modifier;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import static org.assertj.core.api.Assertions.assertThat;

class ContainerCascadeMetadataTest {
    @Test
    void everyProductionClassBuildsMetadataWithoutDeprecatedContainerCascade() throws Exception {
        Logger logger = (Logger) LoggerFactory.getLogger("org.hibernate.validator");
        var captured = new ListAppender<ILoggingEvent>(); captured.start(); logger.addAppender(captured);
        try (var factory = Validation.buildDefaultValidatorFactory()) {
            Validator validator = factory.getValidator();
            Path classes = Path.of(OnboardingRequest.class.getProtectionDomain().getCodeSource().getLocation().toURI());
            int cascadedFields = 0;
            try (var paths = Files.walk(classes.resolve("com/uten/imp"))) {
                for (Path file : paths.filter(path -> path.toString().endsWith(".class")).toList()) {
                    String relative = classes.relativize(file).toString().replace('\\', '.').replace('/', '.');
                    String name = relative.substring(0, relative.length() - ".class".length());
                    Class<?> type = Class.forName(name, false, OnboardingRequest.class.getClassLoader());
                    var descriptor = validator.getConstraintsForClass(type);
                    for (var field : type.getDeclaredFields()) {
                        if (Modifier.isStatic(field.getModifiers()) || !container(field.getType())) continue;
                        assertThat(field.isAnnotationPresent(Valid.class)).as(name + "." + field.getName()).isFalse();
                        if (elementCascade(field.getAnnotatedType())) {
                            cascadedFields++;
                            var property = descriptor.getConstraintsForProperty(field.getName());
                            assertThat(property).as(name + "." + field.getName()).isNotNull();
                            assertThat(cascaded(property.getConstrainedContainerElementTypes()))
                                    .as("Real provider cascade metadata: " + name + "." + field.getName()).isTrue();
                        }
                    }
                }
            }
            assertThat(cascadedFields).isGreaterThanOrEqualTo(56);
            assertThat(captured.list).noneMatch(event -> event.getFormattedMessage().contains("HV000271"));
        } finally {
            logger.detachAppender(captured); captured.stop();
        }
    }

    @Test
    void jacksonSavePayloadsStillRejectInvalidChildrenAndKeepNullVersusEmptyCollections() throws Exception {
        var mapper = new ObjectMapper().findAndRegisterModules();
        try (var factory = Validation.buildDefaultValidatorFactory()) {
            Validator validator = factory.getValidator();
            for (Class<?> type : List.of(
                    com.uten.imp.features.sales.order.dto.OrderSaveRequest.class,
                    com.uten.imp.features.sales.quote.dto.QuoteSaveRequest.class,
                    com.uten.imp.features.stock.dto.StockDocSaveRequest.class,
                    com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest.class)) {
                Object request = mapper.readValue("{\"items\":[{}]}", type);
                assertThat(validator.validate(request)).as(type.getSimpleName())
                        .anyMatch(violation -> violation.getPropertyPath().toString().startsWith("items[0]."));
            }
            var absent = mapper.readValue("{}", UpdateEmployeeRequest.class);
            var empty = mapper.readValue("{\"vehicles\":[],\"phones\":[]}", UpdateEmployeeRequest.class);
            assertThat(absent.vehicles()).isNull(); assertThat(absent.phones()).isNull();
            assertThat(empty.vehicles()).isEmpty(); assertThat(empty.phones()).isEmpty();
            assertThat(validator.validate(absent)).isEmpty(); assertThat(validator.validate(empty)).isEmpty();
        }
    }

    private static boolean cascaded(Set<ContainerElementTypeDescriptor> elements) {
        return elements.stream().anyMatch(element -> element.isCascaded()
                || cascaded(element.getConstrainedContainerElementTypes()));
    }

    private static boolean elementCascade(AnnotatedType type) {
        if (!(type instanceof AnnotatedParameterizedType generic)) return false;
        for (AnnotatedType element : generic.getAnnotatedActualTypeArguments()) {
            if (element.isAnnotationPresent(Valid.class) || elementCascade(element)) return true;
        }
        return false;
    }

    private static boolean container(Class<?> type) {
        return Collection.class.isAssignableFrom(type) || Map.class.isAssignableFrom(type)
                || Optional.class.isAssignableFrom(type) || Iterable.class.isAssignableFrom(type);
    }
}
