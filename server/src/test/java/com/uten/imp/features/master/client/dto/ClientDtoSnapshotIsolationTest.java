package com.uten.imp.features.master.client.dto;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.ConstraintViolation;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PositiveOrZero;
import jakarta.validation.constraints.Size;
import org.junit.jupiter.api.Test;

import java.lang.reflect.Constructor;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.*;

class ClientDtoSnapshotIsolationTest {
    private static final UUID FIRST = UUID.fromString("00000000-0000-0000-0000-000000000001");
    private static final UUID SECOND = UUID.fromString("00000000-0000-0000-0000-000000000002");
    private static final ObjectMapper JSON = new ObjectMapper();

    @Test void accessDetailKeepsBothOwnerAndViewerSnapshots() {
        var viewer = new ClientAccessViewer(FIRST, "First", "E1", "Sales");
        var owner = new ClientAccessViewer(SECOND, "Second", "E2", "Finance");
        var viewers = new ArrayList<>(List.of(viewer));
        var owners = new ArrayList<>(List.of(owner));
        var detail = new ClientAccessDetail(FIRST, SECOND, "Second", 3L, viewers, owners);
        viewers.clear();
        owners.clear();
        assertEquals(List.of(viewer), detail.viewers());
        assertEquals(List.of(owner), detail.owners());
        assertThrows(UnsupportedOperationException.class, () -> detail.viewers().clear());
        assertThrows(UnsupportedOperationException.class, () -> detail.owners().set(0, viewer));
        assertEquals(List.of(), new ClientAccessDetail(FIRST, SECOND, "Second", 3L, null).owners());
        assertNull(new ClientAccessDetail(FIRST, SECOND, "Second", 3L, null, null).owners());
    }

    @Test void singleRequestFreezesTheSelectionBeforeAuthorization() {
        var viewers = new ArrayList<>(List.of(FIRST));
        var owners = new ArrayList<>(List.of(SECOND, FIRST));
        var request = new ClientAccessUpdateRequest(SECOND, viewers, 0L, "Maintain access", owners);
        viewers.clear();
        owners.set(0, FIRST);
        assertEquals(List.of(FIRST), request.viewerEmployeeIds());
        assertEquals(List.of(SECOND, FIRST), request.ownerEmployeeIds());
        assertThrows(UnsupportedOperationException.class, () -> request.viewerEmployeeIds().clear());
        assertThrows(UnsupportedOperationException.class, () -> request.ownerEmployeeIds().add(SECOND));
        assertNull(new ClientAccessUpdateRequest(SECOND, null, 0L, "Maintain access").ownerEmployeeIds());
    }

    @Test void batchRequestPreservesOriginalOrderDuplicatesAndUntouchedDimensions() {
        var clients = new ArrayList<>(List.of(SECOND, FIRST, SECOND));
        var viewers = new ArrayList<>(List.of(FIRST));
        var owners = new ArrayList<>(List.of(SECOND, FIRST));
        var request = new ClientAccessBatchUpdateRequest(clients, null, viewers, "Maintain access", owners);
        clients.clear();
        viewers.clear();
        owners.clear();
        assertEquals(List.of(SECOND, FIRST, SECOND), request.clientIds());
        assertEquals(List.of(FIRST), request.viewerEmployeeIds());
        assertEquals(List.of(SECOND, FIRST), request.ownerEmployeeIds());
        assertThrows(UnsupportedOperationException.class, () -> request.clientIds().clear());
        assertThrows(UnsupportedOperationException.class, () -> request.viewerEmployeeIds().clear());
        assertThrows(UnsupportedOperationException.class, () -> request.ownerEmployeeIds().clear());
        var previousConstructor = new ClientAccessBatchUpdateRequest(null, SECOND, null, "Maintain access");
        assertNull(previousConstructor.clientIds());
        assertNull(previousConstructor.viewerEmployeeIds());
        assertNull(previousConstructor.ownerEmployeeIds());
    }

    @Test void malformedNullElementsStillReachTheExistingStructuredValidator() {
        var nullOwner = new ArrayList<UUID>(Arrays.asList((UUID) null));
        var single = new ClientAccessUpdateRequest(SECOND, null, 0L, "Maintain access", nullOwner);
        var batch = new ClientAccessBatchUpdateRequest(List.of(FIRST), null, null, "Maintain access", nullOwner);
        nullOwner.clear();
        assertNull(single.ownerEmployeeIds().getFirst());
        assertNull(batch.ownerEmployeeIds().getFirst());
        try (var factory = Validation.buildDefaultValidatorFactory()) {
            var validator = factory.getValidator();
            assertTrue(validator.validate(single).stream().anyMatch(error ->
                    error.getPropertyPath().toString().startsWith("ownerEmployeeIds[0]")
                            && error.getConstraintDescriptor().getAnnotation().annotationType().getSimpleName().equals("NotNull")));
            assertTrue(validator.validate(batch).stream().anyMatch(error ->
                    error.getPropertyPath().toString().startsWith("ownerEmployeeIds[0]")
                            && error.getConstraintDescriptor().getAnnotation().annotationType().getSimpleName().equals("NotNull")));
        }
    }

    @Test void jsonKeepsMissingNullAndEmptySelectionsDistinct() throws Exception {
        String common = "\"expectedAccessVersion\":0,\"reason\":\"Maintain access\"";
        var missing = JSON.readValue("{" + common + "}", ClientAccessUpdateRequest.class);
        var explicitNull = JSON.readValue("{" + common + ",\"ownerEmployeeIds\":null,\"viewerEmployeeIds\":null}", ClientAccessUpdateRequest.class);
        var empty = JSON.readValue("{" + common + ",\"ownerEmployeeIds\":[],\"viewerEmployeeIds\":[]}", ClientAccessUpdateRequest.class);
        assertNull(missing.ownerEmployeeIds());
        assertNull(missing.viewerEmployeeIds());
        assertEquals(missing, explicitNull);
        assertEquals(List.of(), empty.ownerEmployeeIds());
        assertEquals(List.of(), empty.viewerEmployeeIds());
        assertNotEquals(missing, empty);
        assertEquals(empty, JSON.readValue(JSON.writeValueAsBytes(empty), ClientAccessUpdateRequest.class));

        var batchMissing = JSON.readValue("{\"clientIds\":[\"" + FIRST + "\"],\"reason\":\"Maintain access\"}", ClientAccessBatchUpdateRequest.class);
        var batchEmpty = JSON.readValue("{\"clientIds\":[\"" + FIRST + "\"],\"reason\":\"Maintain access\",\"ownerEmployeeIds\":[],\"viewerEmployeeIds\":[]}", ClientAccessBatchUpdateRequest.class);
        assertNull(batchMissing.ownerEmployeeIds());
        assertNull(batchMissing.viewerEmployeeIds());
        assertEquals(List.of(), batchEmpty.ownerEmployeeIds());
        assertEquals(List.of(), batchEmpty.viewerEmployeeIds());
        assertEquals(batchEmpty, JSON.readValue(JSON.writeValueAsBytes(batchEmpty), ClientAccessBatchUpdateRequest.class));
    }

    @Test void listAndDetailAllArgumentConstructorsTakePrivateSnapshots() throws Exception {
        var ids = new ArrayList<>(List.of(SECOND, FIRST));
        var names = new ArrayList<>(List.of("Second", "First"));
        ClientDetail detail = construct(ClientDetail.class, ids, names);
        ClientListItem item = construct(ClientListItem.class, ids, names);
        ids.clear();
        names.clear();
        assertEquals(List.of(SECOND, FIRST), detail.getOwnerEmployeeIds());
        assertEquals(List.of("Second", "First"), detail.getOwnerEmployeeNames());
        assertEquals(List.of(SECOND, FIRST), item.getOwnerEmployeeIds());
        assertEquals(List.of("Second", "First"), item.getOwnerEmployeeNames());
        assertThrows(UnsupportedOperationException.class, () -> detail.getOwnerEmployeeIds().clear());
        assertThrows(UnsupportedOperationException.class, () -> detail.getOwnerEmployeeNames().clear());
        assertThrows(UnsupportedOperationException.class, () -> item.getOwnerEmployeeIds().clear());
        assertThrows(UnsupportedOperationException.class, () -> item.getOwnerEmployeeNames().clear());
    }

    @Test void listAndDetailSettersKeepTheSameWirePropertiesWithoutInputAliases() throws Exception {
        ClientDetail detail = construct(ClientDetail.class, null, null);
        ClientListItem item = construct(ClientListItem.class, null, null);
        var ids = new ArrayList<>(List.of(SECOND, FIRST));
        var names = new ArrayList<>(List.of("Second", "First"));
        detail.setOwnerEmployeeIds(ids);
        detail.setOwnerEmployeeNames(names);
        item.setOwnerEmployeeIds(ids);
        item.setOwnerEmployeeNames(names);
        ids.clear();
        names.clear();
        for (Object dto : List.of(detail, item)) {
            var wire = JSON.valueToTree(dto);
            assertEquals(JSON.valueToTree(List.of(SECOND, FIRST)), wire.get("ownerEmployeeIds"));
            assertEquals(JSON.valueToTree(List.of("Second", "First")), wire.get("ownerEmployeeNames"));
            assertFalse(wire.get("financialWritable").booleanValue());
        }
        detail.setOwnerEmployeeIds(null);
        detail.setOwnerEmployeeNames(null);
        item.setOwnerEmployeeIds(null);
        item.setOwnerEmployeeNames(null);
        assertNull(detail.getOwnerEmployeeIds());
        assertNull(detail.getOwnerEmployeeNames());
        assertNull(item.getOwnerEmployeeIds());
        assertNull(item.getOwnerEmployeeNames());
        assertTrue(JSON.valueToTree(detail).get("ownerEmployeeIds").isNull());
        assertTrue(JSON.valueToTree(item).get("ownerEmployeeNames").isNull());
    }

    @Test void explicitValuesKeepTheOriginalRecordHashTextEqualityAndJsonContracts() throws Exception {
        for (List<UUID> ids : Arrays.<List<UUID>>asList(null, List.of(), List.of(SECOND, FIRST))) {
            var single = new ClientAccessUpdateRequest(FIRST, ids, 2L, "Maintain access", ids);
            assertValueContract(single,
                    new ClientAccessUpdateRequest(FIRST, ids, 2L, "Maintain access", ids),
                    new PreviousUpdateRequest(FIRST, ids, 2L, "Maintain access", ids));
            var batch = new ClientAccessBatchUpdateRequest(ids, FIRST, ids, "Maintain access", ids);
            assertValueContract(batch,
                    new ClientAccessBatchUpdateRequest(ids, FIRST, ids, "Maintain access", ids),
                    new PreviousBatchRequest(ids, FIRST, ids, "Maintain access", ids));
        }
        var viewer = new ClientAccessViewer(FIRST, "First", "E1", "Sales");
        for (List<ClientAccessViewer> values : Arrays.<List<ClientAccessViewer>>asList(null, List.of(), List.of(viewer))) {
            var detail = new ClientAccessDetail(FIRST, SECOND, null, 1L << 40, values, values);
            assertValueContract(detail,
                    new ClientAccessDetail(FIRST, SECOND, null, 1L << 40, values, values),
                    new PreviousAccessDetail(FIRST, SECOND, null, 1L << 40, values, values));
        }
    }

    @Test void singleRequestFieldConstructorAndAccessorValidationMatchesTheOriginalRecord() throws Exception {
        try (var factory = Validation.buildDefaultValidatorFactory()) {
            Validator validator = factory.getValidator();
            List<UUID> nullElement = Collections.singletonList(null);
            List<UUID> tooMany = Collections.nCopies(RequestLimits.ADMIN_SCOPE_OWNERS + 1, FIRST);
            assertUpdateValidationParity(validator, null, nullElement, null, "", nullElement);
            assertUpdateValidationParity(validator, FIRST, tooMany, -1L, "x".repeat(1001), tooMany);
            assertUpdateValidationParity(validator, FIRST, null, 0L, "Maintain access", List.of());
        }
    }

    @Test void batchRequestFieldConstructorAndAccessorValidationMatchesTheOriginalRecord() throws Exception {
        try (var factory = Validation.buildDefaultValidatorFactory()) {
            Validator validator = factory.getValidator();
            List<UUID> nullElement = Collections.singletonList(null);
            List<UUID> tooManyOwners = Collections.nCopies(RequestLimits.ADMIN_SCOPE_OWNERS + 1, FIRST);
            List<UUID> tooManyClients = Collections.nCopies(RequestLimits.BATCH_IDS + 1, FIRST);
            assertBatchValidationParity(validator, null, null, nullElement, "", nullElement);
            assertBatchValidationParity(validator, tooManyClients, FIRST, tooManyOwners, "x".repeat(1001), tooManyOwners);
            assertBatchValidationParity(validator, List.of(), FIRST, null, "Maintain access", List.of());
            assertBatchValidationParity(validator, nullElement, FIRST, List.of(), "Maintain access", null);
        }
    }

    private static void assertValueContract(Object current, Object equalValue, Object originalRecord) throws Exception {
        assertEquals(current, equalValue);
        assertNotEquals(current, originalRecord);
        assertEquals(originalRecord.hashCode(), current.hashCode());
        assertEquals(originalRecord.toString().replaceFirst(originalRecord.getClass().getSimpleName(),
                current.getClass().getSimpleName()), current.toString());
        assertEquals(JSON.writeValueAsString(originalRecord), JSON.writeValueAsString(current));
        assertEquals(current, JSON.readValue(JSON.writeValueAsBytes(current), current.getClass()));
    }

    private static void assertUpdateValidationParity(Validator validator, UUID owner, List<UUID> viewers,
            Long version, String reason, List<UUID> owners) throws Exception {
        var current = new ClientAccessUpdateRequest(owner, viewers, version, reason, owners);
        var original = new PreviousUpdateRequest(owner, viewers, version, reason, owners);
        assertValidationParity(validator, current, original,
                new Class<?>[]{UUID.class, List.class, Long.class, String.class, List.class},
                new Object[]{owner, viewers, version, reason, owners},
                List.of("ownerEmployeeId", "viewerEmployeeIds", "expectedAccessVersion", "reason", "ownerEmployeeIds"));
    }

    private static void assertBatchValidationParity(Validator validator, List<UUID> clients, UUID owner,
            List<UUID> viewers, String reason, List<UUID> owners) throws Exception {
        var current = new ClientAccessBatchUpdateRequest(clients, owner, viewers, reason, owners);
        var original = new PreviousBatchRequest(clients, owner, viewers, reason, owners);
        assertValidationParity(validator, current, original,
                new Class<?>[]{List.class, UUID.class, List.class, String.class, List.class},
                new Object[]{clients, owner, viewers, reason, owners},
                List.of("clientIds", "ownerEmployeeId", "viewerEmployeeIds", "reason", "ownerEmployeeIds"));
    }

    private static void assertValidationParity(Validator validator, Object current, Object original,
            Class<?>[] signature, Object[] arguments, List<String> accessors) throws Exception {
        assertEquals(violationPaths(validator.validate(original)), violationPaths(validator.validate(current)));
        for (String name : accessors) {
            var currentAccessor = current.getClass().getDeclaredMethod(name);
            var originalAccessor = original.getClass().getDeclaredMethod(name);
            assertEquals(violationPaths(validator.forExecutables().validateReturnValue(original, originalAccessor,
                            originalAccessor.invoke(original))),
                    violationPaths(validator.forExecutables().validateReturnValue(current, currentAccessor,
                            currentAccessor.invoke(current))), name);
        }
        var currentConstructor = current.getClass().getDeclaredConstructor(signature);
        var originalConstructor = original.getClass().getDeclaredConstructor(signature);
        assertEquals(violationPaths(validator.forExecutables().validateConstructorParameters(originalConstructor, arguments)),
                violationPaths(validator.forExecutables().validateConstructorParameters(currentConstructor, arguments)));
    }

    private static Set<String> violationPaths(Set<? extends ConstraintViolation<?>> errors) {
        return errors.stream().map(error -> error.getPropertyPath().toString()
                        .replaceFirst("^(?:ClientAccessUpdateRequest|PreviousUpdateRequest|ClientAccessBatchUpdateRequest|PreviousBatchRequest)\\.", "")
                        + ":" + error.getConstraintDescriptor().getAnnotation().annotationType().getSimpleName())
                .collect(Collectors.toSet());
    }

    // These references retain the original record contracts. They are never mutation targets.
    private record PreviousAccessDetail(UUID clientId, UUID ownerEmployeeId, String ownerEmployeeName,
            long accessVersion, List<ClientAccessViewer> viewers, List<ClientAccessViewer> owners) { }

    private record PreviousUpdateRequest(UUID ownerEmployeeId,
            @Size(max = RequestLimits.ADMIN_SCOPE_OWNERS) List<@NotNull UUID> viewerEmployeeIds,
            @NotNull @PositiveOrZero Long expectedAccessVersion,
            @NotBlank @Size(max = 1000) String reason,
            @Size(max = RequestLimits.ADMIN_SCOPE_OWNERS) List<@NotNull UUID> ownerEmployeeIds) { }

    private record PreviousBatchRequest(@NotEmpty @Size(max = RequestLimits.BATCH_IDS) List<@NotNull UUID> clientIds,
            UUID ownerEmployeeId,
            @Size(max = RequestLimits.ADMIN_SCOPE_OWNERS) List<@NotNull UUID> viewerEmployeeIds,
            @NotBlank @Size(max = 1000) String reason,
            @Size(max = RequestLimits.ADMIN_SCOPE_OWNERS) List<@NotNull UUID> ownerEmployeeIds) { }

    private static <T> T construct(Class<T> type, List<UUID> ids, List<String> names) throws Exception {
        Constructor<?> constructor = type.getConstructors()[0];
        Class<?>[] types = constructor.getParameterTypes();
        Object[] arguments = new Object[types.length];
        for (int index = 0; index < types.length; index++) {
            if (types[index] == boolean.class) arguments[index] = false;
        }
        assertEquals(List.class, types[types.length - 3]);
        assertEquals(List.class, types[types.length - 2]);
        assertEquals(boolean.class, types[types.length - 1]);
        arguments[types.length - 3] = ids;
        arguments[types.length - 2] = names;
        return type.cast(constructor.newInstance(arguments));
    }
}
