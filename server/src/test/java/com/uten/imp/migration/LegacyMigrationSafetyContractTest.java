package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Locale;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;

/** Static safety contract for reviewed, offline legacy import entry points. */
class LegacyMigrationSafetyContractTest {

    private static final Path LEGACY_ROOT = Path.of("legacy_migration");

    @Test
    void hrImportsKeepIdentifierPiiAndAuditTriggersEnabled() throws IOException {
        for (String filename : List.of(
                "migrate_hr_workers.sql", "migrate_hr_roster.sql")) {
            String sql = compact(Files.readString(LEGACY_ROOT.resolve(filename)));
            assertThat(sql)
                    .contains("pg_advisory_xact_lock(1431586126, 282)")
                    .contains("set_config('app.employee_pii_extra_legacy_import', 'v1', true)")
                    .contains("set_config('app.business_identifier_legacy_import', 'on', true)")
                    .doesNotContain("session_replication_role = replica");
        }
    }

    @Test
    void everyHistoricalGoodsStubHasAStableExplicitCode() throws IOException {
        for (String filename : List.of(
                "migrate_production.sql",
                "migrate_stock_docs.sql",
                "migrate_subcontract.sql",
                "migrate_sales.sql")) {
            String sql = compact(Files.readString(LEGACY_ROOT.resolve(filename)));
            assertThat(sql)
                    .contains("insert into goods (legacy_id, code, name, auto_created, "
                            + "code_managed, code_sequence)")
                    .contains("'legacy-g-' || lid")
                    .contains("set code = coalesce(goods.code, excluded.code)")
                    .doesNotContain("insert into goods (legacy_id, name, auto_created, "
                            + "code_managed, code_sequence)");
        }

        String production = compact(Files.readString(
                LEGACY_ROOT.resolve("migrate_production.sql")));
        assertThat(occurrences(production, "session_replication_role = replica"))
                .as("production bootstrap must keep FK and audit triggers active")
                .isZero();
        assertThat(occurrences(production, "session_replication_role = default"))
                .isZero();
    }

    @Test
    void productListImporterRequiresAnExplicitDatabasePasswordAndLocalCapability()
            throws IOException {
        String python = compact(Files.readString(
                LEGACY_ROOT.resolve("import_product_lists.py")));
        assertThat(python)
                .contains("database_password = os.environ.get(\"uten_db_password\")")
                .contains("uten_db_password is required for legacy product-list import")
                .contains("conn.autocommit = false")
                .contains("set_config('app.business_identifier_legacy_import', 'on', true)")
                .doesNotContain("os.environ.get(\"uten_db_password\", \"uten\")");
    }

    @Test
    void hrKeyHandoffUsesPrivateUnpredictableTemporaryFiles() throws IOException {
        String shell = compact(Files.readString(LEGACY_ROOT.resolve("migrate.sh")));
        assertThat(occurrences(shell, "mktemp \"$here/.uten_keys.xxxxxx.sql\""))
                .isEqualTo(2);
        assertThat(occurrences(shell, "chmod 600 \"$keyf\""))
                .isEqualTo(2);
        assertThat(occurrences(shell,
                "exec \"$container\" chmod 600 /tmp/_uten_keys.sql"))
                .isEqualTo(2);
        assertThat(shell).doesNotContain(".uten_keys.tmp.sql");
    }

    @Test
    void destructiveBootstrapRequiresTheExactCurrentFlywayInventory() throws IOException {
        String shell = compact(Files.readString(LEGACY_ROOT.resolve("migrate.sh")));
        assertThat(shell)
                .contains("expected_flyway_migration_count=388")
                .contains("expected_flyway_head=426")
                .contains("uten-imp-flyway-checksums-v1")
                .contains("select count(*), count(*) filter (where success), "
                        + "count(distinct version), coalesce(max(version::integer), 0) "
                        + "from flyway_schema_history where version is not null")
                .contains("select version, script, checksum from flyway_schema_history "
                        + "where version is not null order by installed_rank")
                .contains("cmp -s")
                .contains("tail -n +2 \"$flyway_checksum_manifest\"")
                .contains("'uten-imp-flyway-checksums.tsv'")
                .contains("mapping_version=\"bootstrap-v10-v426\"");

        String legacyReadme = compact(Files.readString(LEGACY_ROOT.resolve("README.md")));
        assertThat(legacyReadme)
                .contains("最高 v426，共 388 个迁移文件、388 个唯一版本")
                .contains("exact-set 一致的 388 行 checksum manifest")
                .contains("bootstrap-v10-v426")
                .contains("v426 不授权跨越或执行尚未获准的破坏性 v425");

        String migrationReadme = compact(Files.readString(
                Path.of("../docs/数据迁移/README.md")));
        // 目录头横幅随共享候选演进而更新；离线 bootstrap 常量仍冻结在 v426/388 旧基线。
        assertThat(migrationReadme)
                .contains("迁移目录头为 v456，共 418 个迁移文件、418 个唯一版本且无重号")
                .contains("源码校验已同步 v426/388 与 `bootstrap-v10-v426`")
                .contains("受保护 388 行 manifest")
                .contains("v426 不授权跨越或执行尚未获准的破坏性 v425");
    }

    @Test
    void fullBootstrapPreflightsOneExactOfflineExportBeforeDatabaseMutation()
            throws IOException {
        String shell = compact(Files.readString(LEGACY_ROOT.resolve("migrate.sh")));
        assertThat(shell)
                .contains("verify_full_bootstrap_export")
                .contains("manifest[\"formatversion\"] != 3")
                .contains("manifest[\"target\"] != \"all\"")
                .contains("serializable-read-transaction")
                .contains("offline source backup digest is missing")
                .contains("export approval reference is missing or invalid")
                .contains("export repository commit does not match the importer candidate")
                .contains("export was not produced by the current reviewed exporter bytes")
                .contains("checksum sidecar is not the exact target=all csv inventory")
                .contains("json manifest is not the exact target=all csv inventory")
                .contains("export row count drift")
                .contains("export digest drift");
        int preflight = shell.indexOf("preflight () {");
        int exportGate = shell.indexOf("verify_full_bootstrap_export", preflight);
        int dockerProbe = shell.indexOf("\"$docker\" version", preflight);
        assertThat(preflight).isGreaterThanOrEqualTo(0);
        assertThat(exportGate).isGreaterThan(preflight).isLessThan(dockerProbe);

        String exporter = compact(Files.readString(
                LEGACY_ROOT.resolve("export_legacy.ps1")));
        assertThat(exporter)
                .contains("begintransaction( [system.data.isolationlevel]::serializable)")
                .contains("$cmd.transaction = $script:exporttransaction")
                .contains("formatversion = 3")
                .contains("legacy_source_backup_sha256")
                .contains("legacy_export_approval_reference")
                .contains("raw server/database identifiers are never persisted")
                .doesNotContain("sourceserver =")
                .doesNotContain("sourcedatabase =");
    }

    @Test
    void fullBootstrapPersistsStructuralReconciliationAndFailsClosed() throws IOException {
        String shell = compact(Files.readString(LEGACY_ROOT.resolve("migrate.sh")));
        assertThat(shell)
                .contains("record_run_file ()")
                .contains("migrate_reconciliation.sql")
                .contains("reconcile_full_bootstrap")
                .contains("reconciliation_state\" != \"24|0")
                .contains("sourcetargetbusinessreconciliationrequired")
                .contains("reconciliation_status=not_run")
                .contains("git -c \"$here/../..\" status --porcelain=v1 --untracked-files=all");

        String reconciliation = compact(Files.readString(
                LEGACY_ROOT.resolve("migrate_reconciliation.sql")));
        assertThat(reconciliation)
                .contains("consumed_csv_inventory")
                .contains("exact_authority_rows")
                .contains("unresolved_current_uuid_relations")
                .contains("unresolved_default_settlement_methods")
                .contains("invalid_credit_floor")
                .contains("unresolved_sales_payment_types")
                .contains("unresolved_sales_shipment_finance_gate_exceptions")
                .contains("v_sales_shipment_finance_gate_migration_exceptions")
                .contains("including legacy_pending")
                .contains("legacy_approved_orders_missing_finance_compatibility")
                .contains("active_placeholder_or_deleted_goods_edges")
                .contains("unresolved_reject_rows")
                .contains("retained_fk_anchor_goods");
        assertThat(occurrences(reconciliation,
                "select :'run_id'::uuid")).isEqualTo(24);
    }

    @Test
    void fullBootstrapLoadsUuidAuthoritiesBeforeGoods() throws IOException {
        String shell = compact(Files.readString(LEGACY_ROOT.resolve("migrate.sh")));
        String branch = shell.substring(shell.lastIndexOf("--bootstrap-all|--all|-a)"));
        assertThat(branch.indexOf("migrate_mould_data"))
                .isLessThan(branch.indexOf("migrate_goods_data"));
        assertThat(branch.indexOf("migrate_client_data"))
                .isLessThan(branch.indexOf("migrate_goods_data"));
        assertThat(branch.indexOf("migrate_supplier_data"))
                .isLessThan(branch.indexOf("migrate_goods_data"));
        assertThat(branch.indexOf("migrate_color_data"))
                .isLessThan(branch.indexOf("migrate_goods_data"));
        assertThat(branch.indexOf("migrate_unit_data"))
                .isLessThan(branch.indexOf("migrate_goods_data"));
    }

    @Test
    void bootstrapSqlNeverDisablesConstraintsOrUsesTruncate() throws IOException {
        try (Stream<Path> scripts = Files.list(LEGACY_ROOT)) {
            for (Path script : scripts
                    .filter(path -> path.getFileName().toString().startsWith("migrate_"))
                    .filter(path -> path.getFileName().toString().endsWith(".sql"))
                    .toList()) {
                String executable = Files.readString(script)
                        .replaceAll("(?s)/\\*.*?\\*/", "")
                        .replaceAll("(?m)--.*$", "")
                        .toLowerCase(Locale.ROOT);
                assertThat(executable)
                        .as(script.getFileName().toString())
                        .doesNotContain("truncate")
                        .doesNotContain("session_replication_role")
                        .doesNotContain("disable trigger");
            }
        }
    }

    @Test
    void runtimeErpDoesNotExposeALegacyDatabaseMigrationChannel() throws IOException {
        Path javaRoot = Path.of("src/main/java/com/uten/imp/legacy");
        assertThat(Files.exists(javaRoot.resolve("config/LegacyProperties.java"))).isFalse();
        assertThat(Files.exists(javaRoot.resolve("reader/LegacySystemItemReader.java"))).isFalse();
        assertThat(Files.exists(javaRoot.resolve(
                "migration/LegacyMigrationOrchestrator.java"))).isFalse();

        String pom = compact(Files.readString(Path.of("pom.xml")));
        assertThat(pom).doesNotContain("mssql-jdbc");

        String controller = compact(Files.readString(
                javaRoot.resolve("web/LegacyMigrationController.java")));
        assertThat(controller)
                .contains("@profile(\"dev\")")
                .contains("@requestmapping(\"/api/admin/dev/legacy-category-seed\")")
                .doesNotContain("/api/admin/legacy-migration")
                .doesNotContain("@postmapping(\"/all\")");

        for (String source : List.of(
                "reader/LegacyCategoryCsvSource.java",
                "migration/MaterialCategoryMigrator.java",
                "migration/MouldCategoryMigrator.java",
                "migration/ClientCategoryMigrator.java",
                "migration/SupplierCategoryMigrator.java")) {
            assertThat(compact(Files.readString(javaRoot.resolve(source))))
                    .as(source)
                    .contains("@profile(\"dev\")");
        }

        String application = compact(Files.readString(
                Path.of("src/main/resources/application.yml")));
        assertThat(application)
                .contains("enabled: ${uten_legacy_enabled:false}")
                .doesNotContain("uten_legacy_db_url")
                .doesNotContain("datasource-url:");
    }

    @Test
    void currentUpgradeRehearsalsReplaceTheObsoleteFixedVersionCloneTest()
            throws IOException {
        Path migrationTests = Path.of("src/test/java/com/uten/imp/migration");
        assertThat(migrationTests.resolve("V244ToV246NonEmptyRehearsalTest.java"))
                .doesNotExist();
        assertThat(migrationTests.resolve("V238ToCurrentSyntheticMigrationPostgresTest.java"))
                .isRegularFile();

        String clone = compact(Files.readString(
                migrationTests.resolve("CurrentHeadNonEmptyCloneRehearsalTest.java")));
        assertThat(clone)
                .contains("uten_run_rehearsal_db_tests")
                .contains("uten_rehearsal_db_expected_start_version")
                .contains("uten_rehearsal_db_system_identifier")
                .contains("uten_rehearsal_backup_sha256")
                .contains("uten_rehearsal_approval_reference")
                .contains("uten_rehearsal_identifier_conflict_sha256")
                .contains("uten_rehearsal_client_settlement_issue_sha256")
                .contains(".cleandisabled(true)")
                .doesNotContain("signed-candidate");
    }

    private static int occurrences(String value, String token) {
        return (value.length() - value.replace(token, "").length()) / token.length();
    }

    private static String compact(String value) {
        return value.toLowerCase(Locale.ROOT).replaceAll("\\s+", " ").trim();
    }
}
