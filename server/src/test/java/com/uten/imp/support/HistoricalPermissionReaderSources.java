package com.uten.imp.support;

import org.springframework.jdbc.core.JdbcTemplate;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Current reader dependencies for pre-V960 migration oracles.
 * The exact migrated source views read empty independent-template bindings, so
 * legacy authorization facts and the oracle's real Flyway upgrade stay intact.
 */
public final class HistoricalPermissionReaderSources {
    private HistoricalPermissionReaderSources() { }

    public static void install(JdbcTemplate jdbc) {
        installBeforeForwardUpgrade(jdbc);
    }

    public static Installation installBeforeForwardUpgrade(JdbcTemplate jdbc) {
        assertThat(jdbc.queryForObject("""
                SELECT to_regclass('public.authorization_user_template_permission_sources') IS NULL
                   AND to_regclass('public.authorization_department_permission_sources') IS NULL
                """, Boolean.class)).as("Only a pre-V960 schema can own temporary reader projections").isTrue();
        boolean createdTemplateCatalog = Boolean.TRUE.equals(jdbc.queryForObject(
                "SELECT to_regclass('public.permission_templates') IS NULL", Boolean.class));
        if (createdTemplateCatalog) {
            MigratedProjectionSchema.createCurrentTables(jdbc, "permission_templates");
        }
        MigratedProjectionSchema.createCurrentTables(jdbc,
                "user_permission_template_bindings", "department_permission_template_bindings");
        MigratedProjectionSchema.createCurrentViews(jdbc,
                "authorization_user_template_permission_sources", "authorization_department_permission_sources");
        assertNoIndependentAssignments(jdbc);
        return new Installation(createdTemplateCatalog);
    }

    public static void assertNoIndependentAssignments(JdbcTemplate jdbc) {
        assertThat(jdbc.queryForObject("""
                SELECT (SELECT count(*) FROM user_permission_template_bindings)
                     + (SELECT count(*) FROM department_permission_template_bindings)
                """, Long.class)).as("Historical authorization oracle must not invent V960 assignments").isZero();
    }

    public static final class Installation {
        private final boolean createdTemplateCatalog;

        private Installation(boolean createdTemplateCatalog) {
            this.createdTemplateCatalog = createdTemplateCatalog;
        }

        /** Only empty reader projections made by this fixture may precede the real V894/V960 DDL. */
        public void removeBeforeForwardUpgrade(JdbcTemplate jdbc) {
            assertNoIndependentAssignments(jdbc);
            if (createdTemplateCatalog) {
                assertThat(jdbc.queryForObject("SELECT count(*) FROM public.permission_templates", Long.class))
                        .as("Never remove template facts while preparing a real forward migration").isZero();
            }
            jdbc.execute("DROP VIEW public.authorization_user_template_permission_sources");
            jdbc.execute("DROP VIEW public.authorization_department_permission_sources");
            jdbc.execute("DROP TABLE public.user_permission_template_bindings");
            jdbc.execute("DROP TABLE public.department_permission_template_bindings");
            if (createdTemplateCatalog) {
                jdbc.execute("DROP TABLE public.permission_templates");
            }
        }
    }
}
