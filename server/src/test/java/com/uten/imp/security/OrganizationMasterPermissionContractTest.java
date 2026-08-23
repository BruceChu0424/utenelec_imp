package com.uten.imp.security;

import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;

import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class OrganizationMasterPermissionContractTest {

    @Test
    void departmentAndPositionWritesUseMatchingControllerAndServiceGates()
            throws Exception {
        Class<?> departmentController = type(
                "com.uten.imp.features.org.department.DepartmentController");
        Class<?> departmentService = type(
                "com.uten.imp.features.org.department.DepartmentService");
        for (Class<?> layer : List.of(departmentController, departmentService)) {
            assertGate(layer, "create", "department:create");
            assertGate(layer, "update",
                    "department:edit", "department:move",
                    "department:manager_assign");
            assertGate(layer, "delete", "department:delete");
        }

        String departmentSource = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/org/department/DepartmentService.java"),
                StandardCharsets.UTF_8);
        assertThat(departmentSource)
                .contains("boolean editChanged")
                .contains("boolean parentChanged")
                .contains("boolean managerChanged")
                .contains("CurrentAuthorityGuard.requireAll(\"department:edit\")")
                .contains("CurrentAuthorityGuard.requireAll(\"department:move\")")
                .contains("CurrentAuthorityGuard.requireAll(\"department:manager_assign\")");

        Class<?> positionController = type(
                "com.uten.imp.features.org.position.PositionController");
        Class<?> positionService = type(
                "com.uten.imp.features.org.position.PositionService");
        for (Class<?> layer : List.of(positionController, positionService)) {
            assertGate(layer, "create", "position:create");
            assertGate(layer, "update", "position:edit");
            assertGate(layer, "delete", "position:delete");
        }
    }

    private static void assertGate(
            Class<?> type, String methodName, String... permissions) {
        Method method = Arrays.stream(type.getDeclaredMethods())
                .filter(candidate -> candidate.getName().equals(methodName))
                .findFirst()
                .orElseThrow();
        PreAuthorize annotation = method.getAnnotation(PreAuthorize.class);
        assertThat(annotation)
                .as(type.getName() + "#" + methodName)
                .isNotNull();
        for (String permission : permissions) {
            assertThat(annotation.value()).contains("'" + permission + "'");
        }
    }

    private static Class<?> type(String name) {
        try {
            return Class.forName(name);
        } catch (ClassNotFoundException error) {
            throw new AssertionError(error);
        }
    }
}
