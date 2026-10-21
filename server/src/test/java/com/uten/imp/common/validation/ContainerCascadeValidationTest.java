package com.uten.imp.common.validation;

import ch.qos.logback.classic.Logger;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.read.ListAppender;
import com.uten.imp.common.columns.ExtraColumnInput;
import com.uten.imp.common.columns.ExtraColumnRequest;
import jakarta.validation.Valid;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import jakarta.validation.ValidatorFactory;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.slf4j.LoggerFactory;

import java.io.File;
import java.lang.reflect.AnnotatedArrayType;
import java.lang.reflect.AnnotatedParameterizedType;
import java.lang.reflect.AnnotatedType;
import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Exercise inherited and nested cascades through the same validator used at the HTTP boundary. */
class ContainerCascadeValidationTest {
    private static ValidatorFactory factory;
    private static Validator validator;

    @BeforeAll
    static void openValidator() {
        factory = Validation.buildDefaultValidatorFactory();
        validator = factory.getValidator();
    }

    @AfterAll
    static void closeValidator() {
        factory.close();
    }

    @Test
    void extraColumnMembersAreValidatedForAllFourDocumentLineTypes() {
        for (ExtraColumnRequest line : lines()) {
            line.setExtraColumns(List.of(new ExtraColumnInput(null, "x".repeat(2001))));
            assertThat(extraColumnPaths(line)).as(line.getClass().getName())
                    .containsExactlyInAnyOrder("extraColumns[0].columnId", "extraColumns[0].value");
        }
    }

    @Test
    void extraColumnNullEmptyAndOptionalValuesKeepTheirExistingMeaning() {
        for (ExtraColumnRequest line : lines()) {
            line.setExtraColumns(null);
            assertThat(extraColumnPaths(line)).isEmpty();
            line.setExtraColumns(List.of());
            assertThat(extraColumnPaths(line)).isEmpty();
            line.setExtraColumns(Arrays.asList(null, new ExtraColumnInput(UUID.randomUUID(), null)));
            assertThat(extraColumnPaths(line)).isEmpty();
            line.setExtraColumns(List.of(new ExtraColumnInput(UUID.randomUUID(), "x".repeat(2000))));
            assertThat(extraColumnPaths(line)).isEmpty();
        }
    }

    @Test
    void extraColumnCountStillRejectsThirtyThreeAndAcceptsThirtyTwo() {
        var line = new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        var column = new ExtraColumnInput(UUID.randomUUID(), "value");
        line.setExtraColumns(Collections.nCopies(32, column));
        assertThat(extraColumnPaths(line)).isEmpty();
        line.setExtraColumns(Collections.nCopies(33, column));
        assertThat(extraColumnPaths(line)).containsExactly("extraColumns");
    }

    @Test
    void documentValidationTraversesBothItemsAndInheritedExtraColumns() {
        var line = new com.uten.imp.features.purchase.order.dto.OrderItemLine();
        line.setGoodsId(UUID.randomUUID());
        line.setQty(BigDecimal.ONE);
        line.setExtraColumns(List.of(new ExtraColumnInput(null, "value")));
        var request = new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        request.setItems(List.of(line));
        assertThat(validator.validate(request)).anySatisfy(violation ->
                assertThat(violation.getPropertyPath().toString())
                        .isEqualTo("items[0].extraColumns[0].columnId"));
    }

    @Test
    void applicationCascadeMetadataDoesNotEmitDeprecatedContainerWarnings() throws Exception {
        Logger logger = (Logger) LoggerFactory.getLogger(
                "org.hibernate.validator.internal.metadata.aggregated.CascadingMetaDataBuilder");
        var captured = new ListAppender<ILoggingEvent>();
        captured.start();
        logger.addAppender(captured);
        try (var metadataFactory = Validation.buildDefaultValidatorFactory()) {
            var metadataValidator = metadataFactory.getValidator();
            Path classesRoot = Path.of(ExtraColumnRequest.class.getProtectionDomain()
                    .getCodeSource().getLocation().toURI());
            List<Path> classFiles;
            try (var paths = Files.walk(classesRoot.resolve("com/uten/imp"))) {
                classFiles = paths.filter(path -> path.toString().endsWith(".class")).toList();
            }
            int inspected = 0;
            for (Path path : classFiles) {
                String name = classesRoot.relativize(path).toString().replace(File.separatorChar, '.');
                Class<?> type = Class.forName(name.substring(0, name.length() - ".class".length()),
                        false, ExtraColumnRequest.class.getClassLoader());
                if (declaresCascade(type)) {
                    metadataValidator.getConstraintsForClass(type);
                    inspected++;
                }
            }
            assertThat(inspected).as("application classes declaring cascaded validation").isPositive();
            assertThat(captured.list).extracting(ILoggingEvent::getFormattedMessage)
                    .noneMatch(message -> message.startsWith("HV000271:"));
        } finally {
            logger.detachAppender(captured);
            captured.stop();
        }
    }

    private static boolean declaresCascade(Class<?> type) {
        for (var field : type.getDeclaredFields()) {
            if (field.isAnnotationPresent(Valid.class) || cascades(field.getAnnotatedType())) return true;
        }
        for (var method : type.getDeclaredMethods()) {
            if (method.isAnnotationPresent(Valid.class) || cascades(method.getAnnotatedReturnType())) return true;
            for (var parameter : method.getParameters()) {
                if (parameter.isAnnotationPresent(Valid.class) || cascades(parameter.getAnnotatedType())) return true;
            }
        }
        for (var constructor : type.getDeclaredConstructors()) {
            for (var parameter : constructor.getParameters()) {
                if (parameter.isAnnotationPresent(Valid.class) || cascades(parameter.getAnnotatedType())) return true;
            }
        }
        return false;
    }

    private static boolean cascades(AnnotatedType type) {
        if (type.isAnnotationPresent(Valid.class)) return true;
        if (type instanceof AnnotatedParameterizedType parameterized) {
            for (var argument : parameterized.getAnnotatedActualTypeArguments()) {
                if (cascades(argument)) return true;
            }
        } else if (type instanceof AnnotatedArrayType array) {
            return cascades(array.getAnnotatedGenericComponentType());
        }
        return false;
    }

    private static List<ExtraColumnRequest> lines() {
        return List.of(
                new com.uten.imp.features.purchase.order.dto.OrderItemLine(),
                new com.uten.imp.features.sales.quote.dto.QuoteItemLine(),
                new com.uten.imp.features.subcontract.order.dto.OrderItemLine(),
                new com.uten.imp.features.sales.order.dto.OrderItemLine());
    }

    private static List<String> extraColumnPaths(ExtraColumnRequest line) {
        return validator.validate(line).stream()
                .map(violation -> violation.getPropertyPath().toString())
                .filter(path -> path.startsWith("extraColumns"))
                .toList();
    }
}
