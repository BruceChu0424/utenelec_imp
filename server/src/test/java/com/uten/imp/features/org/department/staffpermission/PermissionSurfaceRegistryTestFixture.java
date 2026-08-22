package com.uten.imp.features.org.department.staffpermission;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Test-only exact catalog builder; production never uses an in-code fallback. */
public final class PermissionSurfaceRegistryTestFixture {

    private PermissionSurfaceRegistryTestFixture() {
    }

    public static PermissionSurfaceRegistry registry(
            Map<String, Set<String>> catalog) {
        PermissionSurfaceCatalogRepository repository =
                mock(PermissionSurfaceCatalogRepository.class);
        List<PermissionSurfaceCatalogRepository.CatalogRow> rows =
                new ArrayList<>();
        catalog.entrySet().stream()
                .sorted(Map.Entry.comparingByKey())
                .forEach(entry -> {
                    UUID surfaceId = stableId("surface:" + entry.getKey());
                    if (entry.getValue().isEmpty()) {
                        rows.add(new PermissionSurfaceCatalogRepository.CatalogRow(
                                surfaceId,
                                entry.getKey(),
                                entry.getKey(),
                                null,
                                null,
                                null,
                                null,
                                null,
                                null,
                                null,
                                null));
                        return;
                    }
                    entry.getValue().stream()
                            .sorted(Comparator.naturalOrder())
                            .forEach(code -> rows.add(
                                    new PermissionSurfaceCatalogRepository.CatalogRow(
                                            surfaceId,
                                            entry.getKey(),
                                            entry.getKey(),
                                            stableId("permission:" + code),
                                            code,
                                            code,
                                            "test",
                                            "test",
                                            "VIEW",
                                            code,
                                            1)));
                });
        when(repository.loadEnabledCatalog()).thenReturn(List.copyOf(rows));
        return new PermissionSurfaceRegistry(repository);
    }

    private static UUID stableId(String value) {
        return UUID.nameUUIDFromBytes(
                value.getBytes(StandardCharsets.UTF_8));
    }
}
