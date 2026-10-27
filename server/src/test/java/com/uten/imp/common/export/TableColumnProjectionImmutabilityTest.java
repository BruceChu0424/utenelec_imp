package com.uten.imp.common.export;

import org.junit.jupiter.api.Test;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

class TableColumnProjectionImmutabilityTest {
    @Test void authorizationSelectionCannotBeChangedThroughTheOriginalOrReturnedList() {
        var original = new TableColumnProjection.Column("amount", "原始金额", 120d, "money", null);
        var requested = new ArrayList<>(List.of(original));
        var projection = new TableColumnProjection("report", "view_sales", requested);
        requested.clear();
        requested.add(new TableColumnProjection.Column("private-field", "其他字段", 120d, "text", null));
        assertEquals(List.of(original), projection.columns());
        assertThrows(UnsupportedOperationException.class, () -> projection.columns().clear());
        assertThrows(UnsupportedOperationException.class, () -> projection.columns().set(0, original));
        assertThrows(UnsupportedOperationException.class, () -> projection.columns().subList(0, 1).clear());
        var iterator = projection.columns().iterator();
        iterator.next();
        assertThrows(UnsupportedOperationException.class, iterator::remove);
    }

    @Test void selectionKeepsThePreviousRecordValueContract() {
        var column = new TableColumnProjection.Column("amount", "金额", 120d, "money", null);
        for (List<TableColumnProjection.Column> columns : Arrays.<List<TableColumnProjection.Column>>asList(null, List.of(), List.of(column))) {
            var projection = new TableColumnProjection("report", "view_sales", columns);
            var same = new TableColumnProjection("report", "view_sales", columns);
            var previous = new PreviousRecordValue("report", "view_sales", columns);
            assertEquals(projection, same);
            assertEquals(previous.hashCode(), projection.hashCode());
            assertEquals(previous.toString().replaceFirst("PreviousRecordValue", "TableColumnProjection"), projection.toString());
            assertNotEquals(projection, new TableColumnProjection("other", "view_sales", columns));
            assertNotEquals(projection, new TableColumnProjection("report", "other_scope", columns));
            assertNotEquals(projection, previous);
        }
    }

    private record PreviousRecordValue(
            @jakarta.validation.constraints.Size(max=300) String tableKey,
            @jakarta.validation.constraints.Pattern(regexp="[a-z][a-z0-9_]{0,99}") String scope,
            @jakarta.validation.constraints.NotEmpty @jakarta.validation.constraints.Size(max=160)
            List<TableColumnProjection.@jakarta.validation.Valid Column> columns) { }

    @Test void fieldConstructorAndAccessorValidationMatchThePreviousRecord() throws Exception {
        var invalidColumns = List.of(new TableColumnProjection.Column("", "金额", 0d, "money", null));
        var current = new TableColumnProjection("x".repeat(301), "INVALID", invalidColumns);
        var previous = new PreviousRecordValue("x".repeat(301), "INVALID", invalidColumns);
        try (var factory = jakarta.validation.Validation.buildDefaultValidatorFactory()) {
            var validator = factory.getValidator();
            assertEquals(violationPaths(validator.validate(previous)), violationPaths(validator.validate(current)));
            for (String property : List.of("tableKey", "scope", "columns")) {
                var currentAccessor = TableColumnProjection.class.getMethod(property);
                var previousAccessor = PreviousRecordValue.class.getDeclaredMethod(property);
                assertEquals(
                        violationPaths(validator.forExecutables().validateReturnValue(previous, previousAccessor, previousAccessor.invoke(previous))),
                        violationPaths(validator.forExecutables().validateReturnValue(current, currentAccessor, currentAccessor.invoke(current))));
            }
            var currentConstructor = TableColumnProjection.class.getConstructor(String.class, String.class, List.class);
            var previousConstructor = PreviousRecordValue.class.getDeclaredConstructor(String.class, String.class, List.class);
            Object[] parameters = {"x".repeat(301), "INVALID", null};
            assertEquals(
                    violationPaths(validator.forExecutables().validateConstructorParameters(previousConstructor, parameters)),
                    violationPaths(validator.forExecutables().validateConstructorParameters(currentConstructor, parameters)));
        }
    }

    private static java.util.Set<String> violationPaths(java.util.Set<? extends jakarta.validation.ConstraintViolation<?>> errors) {
        return errors.stream().map(error -> error.getPropertyPath().toString()
                        .replaceFirst("^(?:TableColumnProjection|PreviousRecordValue)\\.", "")
                        + ":" + error.getConstraintDescriptor().getAnnotation().annotationType().getSimpleName())
                .collect(java.util.stream.Collectors.toSet());
    }

    @Test void malformedInputRemainsAvailableForTheExistingStructuredValidator() {
        assertNull(new TableColumnProjection("report", "view_sales", null).columns());
        var projection = new TableColumnProjection("report", "view_sales", new ArrayList<>(Arrays.asList((TableColumnProjection.Column) null)));
        assertEquals(1, projection.columns().size());
        assertNull(projection.columns().getFirst());
    }

    @Test void canonicalConstructorKeepsTheJsonContractAndNestedValidation() throws Exception {
        var mapper = new com.fasterxml.jackson.databind.ObjectMapper();
        var valid = mapper.readValue("""
                {"tableKey":"report","scope":"view_sales","columns":[{"key":"amount","label":"金额","width":120,"type":"money"}]}
                """, TableColumnProjection.class);
        var wire = mapper.writeValueAsBytes(valid);
        var roundTrip = mapper.readValue(wire, TableColumnProjection.class);
        // An absent JsonNode becomes an explicit NullNode on JSON round-trip;
        // the public contract is the JSON value, not that Java representation.
        assertEquals(mapper.readTree(wire), mapper.valueToTree(roundTrip));
        try (var factory = jakarta.validation.Validation.buildDefaultValidatorFactory()) {
            var validator = factory.getValidator();
            assertTrue(validator.validate(valid).isEmpty());
            var invalid = mapper.readValue("""
                    {"tableKey":"report","scope":"INVALID","columns":[{"key":"","width":0}]}
                    """, TableColumnProjection.class);
            var paths = validator.validate(invalid).stream().map(error -> error.getPropertyPath().toString())
                    .collect(java.util.stream.Collectors.toSet());
            assertEquals(java.util.Set.of("scope", "columns[0].key", "columns[0].width"), paths);
            var constructor = TableColumnProjection.class.getDeclaredConstructor(String.class, String.class, List.class);
            assertTrue(validator.forExecutables().validateConstructorParameters(constructor,
                    new Object[]{"report", "view_sales", valid.columns()}).isEmpty());
            assertFalse(validator.forExecutables().validateConstructorParameters(constructor,
                    new Object[]{"report", "view_sales", null}).isEmpty());
        }
    }
}
