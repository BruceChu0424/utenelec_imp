package com.uten.imp.migration;

import com.uten.imp.features.production.analysis.MaterialAnalysisController;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;

import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.CrossReallocationRequest;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.CrossReallocationRevokeRequest;
import static org.assertj.core.api.Assertions.assertThat;

class CrossReallocationPermissionContractTest {

    private static final String AUTHORITY =
            "hasAuthority('production_material_analysis:view') and "
                    + "hasAuthority('production_material_analysis:cross_reallocate')";
    private static final Path V135 = migration("V135__authorization_versioning.sql");
    private static final Path V311 = migration(
            "V311__preplan_reallocation_authority_and_lifecycle.sql");

    @Test
    void permissionIsCataloguedAsDedicatedProductionActionWithRestrictedDefaults()
            throws Exception {
        String sql = compact(V311);

        assertThat(sql).contains(
                "('production_material_analysis:cross_reallocate', "
                        + "'跨物料分析让料与优先补齐', '生产管理', '物料分析', 218)");
        assertThat(sql).contains("department.code in ('gm', 'sub_plan')");
        assertThat(sql).doesNotContain("'dept_pmc'");
        assertThat(sql).doesNotContain("insert into role_permissions");
    }

    @Test
    void departmentAndPersonalGrantChangesInvalidateVersionedAuthorization()
            throws Exception {
        String sql = compact(V135);

        assertThat(sql).contains(
                "create trigger trg_user_permission_overrides_auth_version "
                        + "after insert or update or delete on user_permission_overrides");
        assertThat(sql).contains(
                "create trigger trg_department_permissions_authorization_epoch "
                        + "after insert or update or delete or truncate on department_permissions");
    }

    @Test
    void candidateCreateAndRevokeEndpointsUseOnlyTheDedicatedActionAuthority()
            throws Exception {
        assertAuthority(MaterialAnalysisController.class.getDeclaredMethod(
                "crossReallocationCandidates", UUID.class, UUID.class,
                String.class, int.class, int.class));
        assertAuthority(MaterialAnalysisController.class.getDeclaredMethod(
                "createCrossReallocation", UUID.class,
                CrossReallocationRequest.class));
        assertAuthority(MaterialAnalysisController.class.getDeclaredMethod(
                "revokeCrossReallocation", UUID.class, UUID.class,
                CrossReallocationRevokeRequest.class));
    }

    private static void assertAuthority(Method method) {
        assertThat(method.getAnnotation(PreAuthorize.class))
                .isNotNull()
                .extracting(PreAuthorize::value)
                .isEqualTo(AUTHORITY);
    }

    private static Path migration(String name) {
        return Path.of("src/main/resources/db/migration", name);
    }

    private static String compact(Path path) throws Exception {
        return Files.readString(path, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
