package com.uten.imp.migration;

import org.flywaydb.core.api.Location;
import org.flywaydb.core.internal.resolver.ChecksumCalculator;
import org.flywaydb.core.internal.resource.filesystem.FileSystemResource;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.BindMode;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.images.builder.ImageFromDockerfile;
import org.testcontainers.images.builder.Transferable;
import org.testcontainers.utility.DockerImageName;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.DriverManager;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Current shell-entry safety contracts: v18 aliases reject before any mutation;
 * a deliberately downgraded v15 nonempty source is rejected by V913 and rolls
 * back every business payload. Retired positive/replay/late-finance contracts
 * cannot run against this current protocol. The real Python child contracts
 * remain; this class is not a full v18 business import or user acceptance test.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class LegacyBootstrapCoordinatorPostgresTest {
    private static PostgreSQLContainer postgres;
    private static String clusterId;
    private static String activeDatabase;
    private static String sourceBackupDigest;
    private static Path candidate;
    private static final String ROOT = "/bootstrap";
    private static final String FIXTURE_NONCE = UUID.randomUUID().toString();
    private static String currentMappingVersion;
    private static String preservedAdministratorLogin;
    private static String preservedAdministratorIdentity;

    @BeforeAll
    static void start() throws Exception {
        // Freeze all inputs once before migration. A teammate editing the shared
        // checkout later cannot mix a new loader with an older migrated schema.
        candidate = Files.createTempDirectory("uten-legacy-candidate-");
        Path legacy = candidate.resolve("server/legacy_migration");
        Files.createDirectories(legacy);
        try (var files = Files.list(Path.of("legacy_migration"))) {
            for (Path file : files.filter(Files::isRegularFile).toList()) {
                String name = file.getFileName().toString();
                if (name.equals("migrate.sh") || name.equals("export_legacy.ps1") || name.endsWith(".py")
                        || name.equals("mapping-version.txt") || name.endsWith(".sql")) {
                    Files.copy(file, legacy.resolve(name));
                }
            }
        }
        // Current child contracts inspect the real mapping and reviewed crosswalk.
        // Install the deliberately downgraded synthetic inputs only after they pass.
        Files.copy(Path.of("legacy_migration/warehouse_crosswalk.csv"), legacy.resolve("warehouse_crosswalk.csv"));
        currentMappingVersion = Files.readString(legacy.resolve("mapping-version.txt"), StandardCharsets.UTF_8);
        var loader = LegacyBootstrapCoordinatorPostgresTest.class.getClassLoader();
        Path migrationDirectory = candidate.resolve("server/src/main/resources/db/migration");
        Files.createDirectories(migrationDirectory);
        try (var files = Files.list(Path.of(loader.getResource("db/migration").toURI()))) {
            for (Path file : files.filter(path -> path.getFileName().toString().endsWith(".sql")).toList()) {
                assertThat(Files.readAllBytes(file)).as("compiled migration matches the source candidate: " + file.getFileName())
                        .isEqualTo(Files.readAllBytes(Path.of("src/main/resources/db/migration").resolve(file.getFileName())));
                Files.copy(file, migrationDirectory.resolve(file.getFileName()));
            }
        }
        Path originalFixtures = Path.of("src/test/resources/legacy-bootstrap-fixture");
        Path fixtures = candidate.resolve("server/src/test/resources/legacy-bootstrap-fixture");
        try (var files = Files.walk(originalFixtures)) {
            for (Path file : files.filter(Files::isRegularFile).toList()) {
                Path target = fixtures.resolve(originalFixtures.relativize(file));
                Files.createDirectories(target.getParent());
                Files.copy(file, target);
            }
        }
        var image = new ImageFromDockerfile()
                .withDockerfileFromBuilder(builder -> builder.from("postgres:16-alpine")
                        .run("apk add --no-cache bash python3 py3-pip git coreutils docker-cli")
                        // Alpine does not package xlrd. Keep its pure-Python wheel
                        // hash-locked inside this private fixture, never install
                        // into the distribution's externally managed interpreter.
                        .run("python3 -m venv /opt/legacy-fixture"
                                + " && printf '%s\\n' 'xlrd==2.0.2 --hash=sha256:ea762c3d29f4cca48d82df517b6d89fbce4db3107f9d78713e48cd321d5c9aa9' > /tmp/legacy-fixture-requirements.txt"
                                + " && /opt/legacy-fixture/bin/python -m pip download --disable-pip-version-check --no-cache-dir --no-deps --only-binary=:all: --require-hashes -r /tmp/legacy-fixture-requirements.txt -d /tmp/legacy-fixture-wheels"
                                + " && sha256sum /tmp/legacy-fixture-wheels/xlrd-2.0.2-py2.py3-none-any.whl"
                                + " && /opt/legacy-fixture/bin/python -m pip install --disable-pip-version-check --no-index --no-deps --require-hashes --find-links=/tmp/legacy-fixture-wheels -r /tmp/legacy-fixture-requirements.txt"
                                + " && /opt/legacy-fixture/bin/python -m pip check"
                                + " && /opt/legacy-fixture/bin/python -I -c \"import xlrd; assert xlrd.__version__ == '2.0.2'\"")
                        .env("PATH", "/opt/legacy-fixture/bin:$PATH")
                        .build());
        postgres = new PostgreSQLContainer(DockerImageName.parse(image.get()).asCompatibleSubstituteFor("postgres"))
                .withDatabaseName("legacy_bootstrap_rehearsal")
                .withUsername("fixture_admin").withPassword("synthetic-test-only")
                .withFileSystemBind("/var/run/docker.sock", "/var/run/docker.sock", BindMode.READ_WRITE)
                .withCommand("postgres", "-c", "max_locks_per_transaction=512");
        postgres.withLabel("uten.imp.legacy.fixture", FIXTURE_NONCE);
        postgres.start();
        activeDatabase = postgres.getDatabaseName();
        com.uten.imp.testsupport.TestFlyway.configure().dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                .locations("filesystem:" + migrationDirectory).load().migrate();
        seedPreservedAdministrator(legacy);
        clusterId = scalar("SELECT system_identifier FROM pg_control_system()");
        shell("mkdir -p /bootstrap/server/legacy_migration /bootstrap/server/src/main/resources/db/migration /bootstrap/server/target");
        try (var files = Files.list(legacy)) {
            for (Path file : files.filter(Files::isRegularFile).toList()) {
                String name = file.getFileName().toString();
                if (name.equals("migrate.sh") || name.equals("export_legacy.ps1") || name.endsWith(".py")
                        || name.equals("mapping-version.txt") || name.endsWith(".sql")
                        || name.equals("warehouse_crosswalk.csv")) {
                    put(ROOT + "/server/legacy_migration/" + name, Files.readAllBytes(file));
                }
            }
        }
        List<Path> migrations;
        try (var files = Files.list(migrationDirectory)) {
            migrations = files.filter(path -> path.getFileName().toString().endsWith(".sql"))
                    .sorted(Comparator.comparingInt(LegacyBootstrapCoordinatorPostgresTest::version)).toList();
        }
        StringBuilder manifest = new StringBuilder("# uten-imp-flyway-checksums-v1\n");
        for (Path file : migrations) {
            String name = file.getFileName().toString();
            put(ROOT + "/server/src/main/resources/db/migration/" + name, Files.readAllBytes(file));
            var resource = new FileSystemResource(Location.fromPath("filesystem:", migrationDirectory.toString()),
                    file.toString(), StandardCharsets.UTF_8, false);
            manifest.append(version(file)).append('\t').append(name).append('\t')
                    .append(ChecksumCalculator.calculate(resource)).append('\n');
        }
        put(ROOT + "/server/target/uten-imp-flyway-checksums.tsv", manifest.toString());
        put(ROOT + "/.gitignore", "server/.env\nserver/target/\nserver/legacy_migration/data/\nsynthetic-source-snapshot.json\n__pycache__/\n");
        put(ROOT + "/server/.env", "UTEN_PGP_MASTER_KEY=synthetic-test-only-pgp-material-0001\nUTEN_HMAC_KEY=synthetic-test-only-hmac-material-0001\nUTEN_PGP_KEY_VERSION=test-v1\n");
        shell("mkdir -p /bootstrap/server/src/test/resources/legacy-bootstrap-fixture/variants");
        try (var files = Files.walk(fixtures)) {
            for (Path file : files.filter(Files::isRegularFile).toList()) {
                put(ROOT + "/server/src/test/resources/legacy-bootstrap-fixture/" + fixtures.relativize(file).toString().replace('\\','/'), Files.readAllBytes(file));
            }
        }
        shell("cd /bootstrap && git init -q && git config user.name 'Synthetic fixture' && git config user.email 'synthetic@example.invalid' && git add . && git commit -qm 'Isolated synthetic importer candidate'");
        var pythonTests = postgres.execInContainer("env",
                "UTEN_LEGACY_TEST_PG_CONTAINER=" + postgres.getContainerId(),
                "UTEN_LEGACY_TEST_PG_DATABASE=" + postgres.getDatabaseName(),
                "UTEN_LEGACY_TEST_PG_USER=" + postgres.getUsername(),
                "UTEN_LEGACY_TEST_PG_NONCE=" + FIXTURE_NONCE,
                "bash", "-euc", "cd /bootstrap && exec python3 -m unittest discover -s server/legacy_migration -p 'test_*.py' -v");
        System.out.print(pythonTests.getStdout());
        System.out.print(pythonTests.getStderr());
        assertThat(pythonTests.getExitCode()).withFailMessage(pythonTests.getStdout() + pythonTests.getStderr()).isZero();
        // ADR-145: the subsequent historical negative lane uses its own exact
        // warehouse identities and v15. Keep this private candidate clean so its
        // freeze gate still checks the deliberate inputs rather than bypassing it.
        put(ROOT + "/server/legacy_migration/warehouse_crosswalk.csv",
                Files.readAllBytes(fixtures.resolve("warehouse_crosswalk.csv")));
        put(ROOT + "/server/legacy_migration/mapping-version.txt", "bootstrap-v15\n");
        shell("cd /bootstrap && git add server/legacy_migration/warehouse_crosswalk.csv server/legacy_migration/mapping-version.txt"
                + " && git commit -qm 'Isolated historical v15 rejection inputs'");
        generateFixture();
    }

    @AfterAll
    static void stop() throws Exception {
        if (postgres != null) postgres.stop();
        if (candidate != null && Files.exists(candidate)) {
            Path resolved = candidate.toRealPath();
            assertThat(resolved.getParent()).isEqualTo(Path.of(System.getProperty("java.io.tmpdir")).toRealPath());
            assertThat(resolved.getFileName().toString()).startsWith("uten-legacy-candidate-");
            try (var files = Files.walk(resolved)) {
                for (Path file : files.sorted(Comparator.reverseOrder()).toList()) Files.delete(file);
            }
        }
    }

    @Test
    void downgradedV15NonemptyProductionIsRejectedAndEveryBusinessWriteRollsBack() throws Exception {
        Map<String, String> beforeBusiness = databaseFingerprints(false, null);
        String beforeSequenceDefinitions = sequenceDefinitionsFingerprint();
        // Bad provenance and a contested lock must fail before a run or any business write.
        String before = scalar("SELECT count(*) FROM legacy_migration_runs");
        var wrongTarget = coordinator("UTEN_LEGACY_TARGET_DB_EXPECTED_NAME=wrong_target");
        assertThat(wrongTarget.getExitCode()).isNotZero();
        assertThat(coordinator("UTEN_LEGACY_TARGET_SYSTEM_IDENTIFIER=1").getExitCode()).isNotZero();
        assertThat(coordinator("UTEN_LEGACY_TARGET_APPROVAL_REFERENCE=").getExitCode()).isNotZero();
        assertThat(coordinator("LEGACY_SOURCE_SNAPSHOT_AS_OF_UTC=").getExitCode()).isNotZero();
        assertThat(coordinator("LEGACY_SOURCE_SNAPSHOT_AS_OF_UTC=2025-02-01T00:00:00Z").getExitCode()).isNotZero();
        var unauthorized = coordinator("LEGACY_EXPORT_APPROVAL_REFERENCE=unapproved-test-reference");
        assertThat(unauthorized.getExitCode()).isNotZero();
        shell("cp /bootstrap/server/target/uten-imp-flyway-checksums.tsv /tmp/valid-manifest && sed -i '$d' /bootstrap/server/target/uten-imp-flyway-checksums.tsv");
        assertThat(coordinator().getExitCode()).isNotZero();
        shell("cp /tmp/valid-manifest /bootstrap/server/target/uten-imp-flyway-checksums.tsv");
        shell("sed -i '2s/[0-9-]*$/42/' /bootstrap/server/target/uten-imp-flyway-checksums.tsv");
        assertThat(coordinator().getExitCode()).isNotZero();
        shell("cp /tmp/valid-manifest /bootstrap/server/target/uten-imp-flyway-checksums.tsv");
        shell("mkdir /tmp/uten-legacy-migration.lock && printf 'owned-by-other-run' >/tmp/uten-legacy-keys.other-run.sql");
        var contested = coordinator();
        assertThat(contested.getExitCode()).withFailMessage(contested.getStdout() + contested.getStderr()).isEqualTo(75);
        shell("test -d /tmp/uten-legacy-migration.lock && test \"$(cat /tmp/uten-legacy-keys.other-run.sql)\" = owned-by-other-run");
        shell("rmdir /tmp/uten-legacy-migration.lock && rm /tmp/uten-legacy-keys.other-run.sql");
        assertThat(scalar("SELECT count(*) FROM legacy_migration_runs")).isEqualTo(before);
        assertThat(scalar("SELECT count(*) FROM goods")).isEqualTo("0");

        // Retired v15 cannot reach the old positive/replay/late-finance path:
        // actual V913 production provenance deliberately requires protocol v17+.
        // Keep production and finance source rows nonempty; never delete a module
        // or weaken its guard to resurrect the retired positive contract.
        shell("test $(wc -l < /bootstrap/server/legacy_migration/data/production_plan_items.csv) -gt 1"
                + " && test $(wc -l < /bootstrap/server/legacy_migration/data/m_get.csv) -gt 1");
        String baselineEmployees = scalar("SELECT count(*) FROM employees");
        var rejected = coordinator();
        assertThat(rejected.getExitCode()).isNotZero();
        assertThat(rejected.getStdout()).withFailMessage(rejected.getStdout() + rejected.getStderr())
                .contains("Bootstrap module: migrate_production.sql")
                .doesNotContain("Bootstrap module: migrate_finance.sql");
        assertThat(rejected.getStderr()).contains("23514");
        assertThat(scalar("SELECT status || '|' || mapping_version || '|' || (exit_code IS NOT NULL AND finished_at IS NOT NULL)::text "
                + "FROM legacy_migration_runs WHERE target='--bootstrap-all' AND migration_mode='BOOTSTRAP'"))
                .isEqualTo("FAILED|bootstrap-v15|true");
        assertThat(scalar("SELECT count(*) FROM legacy_migration_run_files file JOIN legacy_migration_runs run USING(run_id) "
                + "WHERE run.target='--bootstrap-all' AND run.status='FAILED'")).isNotEqualTo("0");
        assertThat(scalar("SELECT count(*) FROM legacy_migration_runs WHERE target='--bootstrap-all' AND migration_mode='BOOTSTRAP'"))
                .isEqualTo("1");
        AllowedFailedAttempt failedAttempt = assertExactFailedAttemptAudit();
        assertBusinessImportRolledBack(baselineEmployees);
        assertThat(scalar("SELECT count(*) FROM legacy_production_plan_counter_import_contexts")).isEqualTo("0");
        assertThat(scalar("SELECT count(*) FROM legacy_production_plan_counter_import_sources")).isEqualTo("0");
        assertThat(databaseFingerprints(false, failedAttempt)).as("every existing payload except the exact validated FAILED attempt evidence must remain unchanged")
                .isEqualTo(beforeBusiness);
        // PostgreSQL sequences can advance outside rollback. Their definitions
        // remain unchanged; v18 early rejection below additionally proves their
        // actual values unchanged because that command must execute no SQL.
        assertThat(sequenceDefinitionsFingerprint()).isEqualTo(beforeSequenceDefinitions);
        assertPreservedAdministrator();
        shell("test ! -d /tmp/uten-legacy-migration.lock && test -z \"$(find /tmp -maxdepth 1 -name 'uten-legacy-keys.*.sql' -print -quit)\"");
    }

    @Test
    void currentProtocolRejectsEveryShellAllAliasBeforeClaimsOrBusinessMutation() throws Exception {
        String path = ROOT + "/server/legacy_migration/mapping-version.txt";
        String before = completeDatabaseFingerprint();
        put(path, currentMappingVersion);
        try {
            for (String alias : List.of("--bootstrap-all", "--all", "-a")) {
                var rejected = coordinatorWithAlias(alias);
                assertThat(rejected.getExitCode()).withFailMessage(rejected.getStdout() + rejected.getStderr()).isEqualTo(64);
                assertThat(rejected.getStderr()).contains("rehearse_local_import.py");
                assertThat(completeDatabaseFingerprint()).as(alias + " must not change any claim, business row or sequence")
                        .isEqualTo(before);
            }
        } finally {
            put(path, "bootstrap-v15\n");
        }
    }

    private static String completeDatabaseFingerprint() throws Exception {
        return java.util.HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256")
                .digest(databaseFingerprints(true, null).toString().getBytes(StandardCharsets.UTF_8)));
    }

    private record AllowedFailedAttempt(UUID runId, String auditTable, String auditPayload) {}

    private static Map<String, String> databaseFingerprints(boolean includeSequences, AllowedFailedAttempt allowed) throws Exception {
        try (var connection = DriverManager.getConnection(jdbcUrl(), postgres.getUsername(), postgres.getPassword());
             var statement = connection.createStatement()) {
            List<String> tables = new ArrayList<>();
            try (var rows = statement.executeQuery("SELECT relname FROM pg_class JOIN pg_namespace n ON n.oid=relnamespace "
                    + "WHERE n.nspname='public' AND relkind='r' ORDER BY relname")) {
                while (rows.next()) tables.add(rows.getString(1));
            }
            Map<String, String> fingerprints = new TreeMap<>();
            for (String table : tables) {
                String quoted = "\"" + table.replace("\"", "\"\"") + "\"";
                boolean attemptTable = allowed != null && List.of("legacy_migration_runs", "legacy_migration_run_files").contains(table);
                boolean auditTable = allowed != null && table.equals(allowed.auditTable());
                String condition = attemptTable ? " WHERE run_id<>?" : auditTable ? " WHERE to_jsonb(t)::text<>?" : "";
                try (var query = connection.prepareStatement("SELECT count(*) || ':' || md5(coalesce("
                        + "string_agg(to_jsonb(t)::text,E'\\n' ORDER BY to_jsonb(t)::text),'')) FROM public." + quoted + " t" + condition)) {
                    if (attemptTable) query.setObject(1, allowed.runId());
                    if (auditTable) query.setString(1, allowed.auditPayload());
                    try (var rows = query.executeQuery()) {
                        rows.next();
                        fingerprints.put(table, rows.getString(1));
                    }
                }
            }
            if (includeSequences) try (var rows = statement.executeQuery("SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY sequencename)::text,'[]') "
                    + "FROM pg_sequences s WHERE schemaname='public'")) {
                rows.next();
                fingerprints.put("#public_sequence_definitions_and_values", rows.getString(1));
            }
            return fingerprints;
        }
    }

    private static AllowedFailedAttempt assertExactFailedAttemptAudit() throws Exception {
        UUID runId = UUID.fromString(scalar("SELECT run_id::text FROM legacy_migration_runs WHERE target='--bootstrap-all' AND migration_mode='BOOTSTRAP'"));
        AllowedFailedAttempt accepted;
        try (var connection = DriverManager.getConnection(jdbcUrl(), postgres.getUsername(), postgres.getPassword());
             var query = connection.prepareStatement("""
                     SELECT relation.relname,to_jsonb(audit)::text,
                       jsonb_strip_nulls(to_jsonb(audit))=jsonb_build_object(
                         'id',audit.id,'created_at',audit.created_at,
                         'actor_account','ops:legacy_migration','action','legacy_migration_run',
                         'target_type','legacy_migration_run','target_id',run.run_id::text,
                         'result','failure','event_source','system','risk_level','high',
                         'event_category','system','device_capture_status','missing',
                         'after',jsonb_build_object('target',run.target,'mode',run.migration_mode,
                           'status',run.status,'exit_code',run.exit_code,
                           'reconciliation_status',run.reconciliation_status,'mapping_version',run.mapping_version,
                           'repository_commit',run.migration_repository_commit,'table_rows',audit."after"->'table_rows'))
                     FROM audit_log audit JOIN pg_class relation ON relation.oid=audit.tableoid
                     JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
                     JOIN legacy_migration_runs run ON audit.target_id=run.run_id::text
                     WHERE run.run_id=? AND run.status='FAILED' AND namespace.nspname='public'
                       AND audit.action='legacy_migration_run' AND audit.target_type='legacy_migration_run'
                     """)) {
            query.setObject(1, runId);
            try (var rows = query.executeQuery()) {
                assertThat(rows.next()).as("ADR105 retains one failed-run summary, not a leaked business write").isTrue();
                assertThat(rows.getBoolean(3)).as("the complete non-null event and after-payload match this exact FAILED run").isTrue();
                accepted = new AllowedFailedAttempt(runId, rows.getString(1), rows.getString(2));
                assertThat(rows.next()).as("exactly one audit summary belongs to this failed run").isFalse();
            }
        }
        Map<String, Long> expectedCounts = new TreeMap<>();
        for (String table : List.of("material_categories", "mould_categories", "client_categories", "supplier_categories",
                "colors", "units", "currencies", "warehouses", "moulds", "clients", "suppliers", "goods", "goods_bom_items",
                "purchase_orders", "purchase_order_items", "purchase_receipts", "purchase_receipt_items", "stock_documents", "stock_document_items",
                "sales_orders", "sales_order_items", "sales_shipments", "sales_shipment_items", "subcontract_orders", "subcontract_order_items",
                "production_plans", "production_plan_items", "production_plan_costs", "finance_receipts", "finance_payments", "ar_ap_ledger", "employees")) {
            expectedCounts.put(table, Long.parseLong(scalar("SELECT count(*) FROM public." + table)));
        }
        Map<String, Long> actualCounts = new TreeMap<>();
        try (var connection = DriverManager.getConnection(jdbcUrl(), postgres.getUsername(), postgres.getPassword());
             var query = connection.prepareStatement("SELECT entry.key,entry.value FROM audit_log audit "
                     + "CROSS JOIN LATERAL jsonb_each_text(audit.\"after\"->'table_rows') entry "
                     + "WHERE audit.target_id=? AND audit.target_type='legacy_migration_run' AND audit.action='legacy_migration_run'")) {
            query.setString(1, runId.toString());
            try (var rows = query.executeQuery()) {
                while (rows.next()) actualCounts.put(rows.getString(1), Long.parseLong(rows.getString(2)));
            }
        }
        assertThat(actualCounts).as("the exact32 table-count summary describes the rolled-back database").isEqualTo(expectedCounts);
        return accepted;
    }

    private static String sequenceDefinitionsFingerprint() throws Exception {
        return scalar("SELECT md5(coalesce(jsonb_agg(to_jsonb(seq)-'last_value' ORDER BY sequencename)::text,'[]')) "
                + "FROM pg_sequences seq WHERE schemaname='public'");
    }

    private static void generateFixture(String... variants) throws Exception {
        String fixtures = ROOT + "/server/src/test/resources/legacy-bootstrap-fixture";
        var command = new ArrayList<>(List.of("python3", fixtures + "/generate_fixture.py", ROOT, fixtures + "/rows.json",
                fixtures + "/variants/finance-facts.json"));
        for (String variant : variants) command.add(fixtures + "/variants/" + variant);
        var generated = postgres.execInContainer(command.toArray(String[]::new));
        assertThat(generated.getExitCode()).withFailMessage(generated.getStdout() + generated.getStderr()).isZero();
        // Current stock composition requires these manual layers even for the
        // historical negative lane. Its synthetic goods have no workshop-bin
        // references: empty reviewed stages authorize no location or opening.
        var manualLayers = postgres.execInContainer("python3", "-c", """
                import csv,pathlib,re,shutil,sys
                legacy=pathlib.Path(sys.argv[1])/'server/legacy_migration'
                data=legacy/'data'
                shutil.copyfile(legacy/'warehouse_crosswalk.csv',data/'warehouse_crosswalk.csv')
                sql=(legacy/'reviewed_workshop_stock_location.sql').read_text(encoding='utf-8')
                for stage,name in re.findall(r"\\\\copy (\\w+) FROM '/tmp/([^']+)'",sql):
                    definition=re.search(r'CREATE TEMP TABLE '+stage+r'\\s*\\((.*?)\\);',sql,re.S).group(1)
                    columns=[column.strip().split()[0] for column in definition.split(',')]
                    with (data/name).open('w',encoding='utf-8',newline='') as target:
                        csv.writer(target,delimiter='|',lineterminator='\\n').writerow(columns)
                sys.path.insert(0,str(legacy))
                from validate_loader_csv_contract import validate_modules
                assert validate_modules([('reviewed_workshop_stock_location.sql',sql)],data)['copy_count']==3
                """, ROOT);
        assertThat(manualLayers.getExitCode()).withFailMessage(manualLayers.getStdout() + manualLayers.getStderr()).isZero();
        var digest = postgres.execInContainer("sha256sum", ROOT + "/synthetic-source-snapshot.json");
        assertThat(digest.getExitCode()).isZero();
        sourceBackupDigest = digest.getStdout().split(" ")[0];
    }

    private static org.testcontainers.containers.Container.ExecResult coordinator(String... overrides) throws Exception {
        return coordinatorWithAlias("--bootstrap-all", overrides);
    }

    private static org.testcontainers.containers.Container.ExecResult coordinatorWithAlias(String alias, String... overrides) throws Exception {
        assertPreservedAdministrator();
        var command = new ArrayList<>(List.of("env", "PG_CONTAINER=" + postgres.getContainerId(),
                "PG_USER=" + postgres.getUsername(), "PG_DB=" + activeDatabase,
                "UTEN_LEGACY_TARGET_DB_EXPECTED_NAME=" + activeDatabase,
                "UTEN_LEGACY_TARGET_SYSTEM_IDENTIFIER=" + clusterId,
                "UTEN_LEGACY_TARGET_APPROVAL_REFERENCE=synthetic-target-approval",
                "LEGACY_SOURCE_AUTHORITY_ID=synthetic-offline-fixture",
                "LEGACY_SOURCE_SNAPSHOT_AS_OF_UTC=2025-01-31T15:59:59Z",
                "LEGACY_SOURCE_BACKUP_SHA256=" + sourceBackupDigest,
                "LEGACY_EXPORT_APPROVAL_REFERENCE=synthetic-test-approval"));
        command.addAll(List.of(overrides));
        command.addAll(List.of("bash", ROOT + "/server/legacy_migration/migrate.sh", alias, "--confirm-destructive"));
        return postgres.execInContainer(command.toArray(String[]::new));
    }

    private static void seedPreservedAdministrator(Path frozenLegacy) throws Exception {
        // V08 supplies the employee; this pure-Flyway fixture has no application
        // BootstrapRunner. Seed its reviewed login before any shell attempt
        // so both protocol rejection contracts preserve the same identity.
        var login = java.util.regex.Pattern.compile("u\\.login_account='([^']+)'").matcher(
                Files.readString(frozenLegacy.resolve("migrate_owner_custody.sql"), StandardCharsets.UTF_8));
        assertThat(login.find()).as("the frozen resolver binds the reviewed custodian login").isTrue();
        preservedAdministratorLogin = login.group(1);
        try (var connection = DriverManager.getConnection(jdbcUrl(), postgres.getUsername(), postgres.getPassword());
             var statement = connection.prepareStatement("""
                     INSERT INTO users(employee_id,login_account,password_hash,is_super_admin,status,is_deleted)
                     SELECT id,?,'!synthetic-coordinator-fixture-no-login',true,'active',false
                     FROM employees WHERE code='ADMIN' AND status='active' AND NOT is_deleted
                     RETURNING id::text || '|' || employee_id::text
                     """)) {
            statement.setString(1, preservedAdministratorLogin);
            try (var rows = statement.executeQuery()) {
                assertThat(rows.next()).as("Flyway preserves the current ADMIN employee").isTrue();
                preservedAdministratorIdentity = rows.getString(1);
                assertThat(rows.next()).as("the preserved administrator is unique").isFalse();
            }
        }
        assertPreservedAdministrator();
    }

    private static void assertPreservedAdministrator() throws Exception {
        try (var connection = DriverManager.getConnection(jdbcUrl(), postgres.getUsername(), postgres.getPassword());
             var statement = connection.prepareStatement("""
                     SELECT account.id::text || '|' || employee.id::text
                     FROM employees employee JOIN users account ON account.employee_id=employee.id
                     WHERE employee.code='ADMIN' AND employee.status='active' AND NOT employee.is_deleted
                       AND account.login_account=? AND account.is_super_admin
                       AND account.status='active' AND NOT account.is_deleted
                     """)) {
            statement.setString(1, preservedAdministratorLogin);
            try (var rows = statement.executeQuery()) {
                assertThat(rows.next()).as("the current variant preserves its reviewed administrator").isTrue();
                assertThat(rows.getString(1)).isEqualTo(preservedAdministratorIdentity);
                assertThat(rows.next()).as("the preserved administrator remains unique").isFalse();
            }
        }
    }

    private static void shell(String command) throws Exception {
        var result = postgres.execInContainer("bash", "-euc", command);
        assertThat(result.getExitCode()).withFailMessage(result.getStdout() + result.getStderr()).isZero();
    }

    private static void put(String path, String text) {
        put(path, text.getBytes(StandardCharsets.UTF_8));
    }

    private static void put(String path, byte[] bytes) {
        postgres.copyFileToContainer(Transferable.of(bytes, 0600), path);
    }

    private static String scalar(String sql) throws Exception {
        try (var connection = DriverManager.getConnection(jdbcUrl(), postgres.getUsername(), postgres.getPassword());
             var statement = connection.createStatement(); var rows = statement.executeQuery(sql)) {
            rows.next();
            return rows.getString(1);
        }
    }

    private static String jdbcUrl() {
        return postgres.getJdbcUrl().replace("/" + postgres.getDatabaseName() + "?", "/" + activeDatabase + "?");
    }

    private static void assertBusinessImportRolledBack(String baselineEmployees) throws Exception {
        for (String table : List.of("goods", "clients", "suppliers", "moulds", "stock_balances", "stock_movements",
                "purchase_orders", "sales_orders", "subcontract_orders", "production_plans", "ar_ap_ledger", "finance_receipts")) {
            assertThat(scalar("SELECT count(*) FROM " + table)).as("rolled back " + table).isEqualTo("0");
        }
        assertThat(scalar("SELECT count(*) FROM employees")).isEqualTo(baselineEmployees);
        assertThat(scalar("SELECT count(*) FROM legacy_migration_runs WHERE target='--bootstrap-all' AND status <> 'FAILED'")).isEqualTo("0");
    }

    private static int version(Path file) {
        String name = file.getFileName().toString();
        return com.uten.imp.testsupport.FixtureNumbers.integer(name.substring(1, name.indexOf("__")));
    }
}
