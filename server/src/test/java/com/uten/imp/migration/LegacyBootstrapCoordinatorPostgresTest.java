package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.Location;
import org.flywaydb.core.internal.resolver.ChecksumCalculator;
import org.flywaydb.core.internal.resource.filesystem.FileSystemResource;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.BindMode;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.PostgreSQLContainer;
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
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Runs the actual shell coordinator, Docker CLI, COPY, provenance and reconciliation gates. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class LegacyBootstrapCoordinatorPostgresTest {
    private static PostgreSQLContainer<?> postgres;
    private static String clusterId;
    private static String activeDatabase;
    private static String sourceBackupDigest;
    private static Path candidate;
    private static final String ROOT = "/bootstrap";

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
                        .run("apk add --no-cache bash python3 git coreutils docker-cli")
                        .build());
        postgres = new PostgreSQLContainer<>(DockerImageName.parse(image.get()).asCompatibleSubstituteFor("postgres"))
                .withDatabaseName("legacy_bootstrap_rehearsal")
                .withUsername("uten").withPassword("synthetic-test-only")
                .withFileSystemBind("/var/run/docker.sock", "/var/run/docker.sock", BindMode.READ_WRITE)
                .withCommand("postgres", "-c", "max_locks_per_transaction=512");
        postgres.start();
        activeDatabase = postgres.getDatabaseName();
        Flyway.configure().dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                .locations("filesystem:" + migrationDirectory).load().migrate();
        clusterId = scalar("SELECT system_identifier FROM pg_control_system()");
        shell("createdb -U uten -T legacy_bootstrap_rehearsal legacy_bootstrap_template");
        shell("mkdir -p /bootstrap/server/legacy_migration /bootstrap/server/src/main/resources/db/migration /bootstrap/server/target");
        try (var files = Files.list(legacy)) {
            for (Path file : files.filter(Files::isRegularFile).toList()) {
                String name = file.getFileName().toString();
                if (name.equals("migrate.sh") || name.equals("export_legacy.ps1") || name.endsWith(".py")
                        || name.equals("mapping-version.txt") || name.endsWith(".sql")) {
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
            var resource = new FileSystemResource(new Location("filesystem:" + migrationDirectory),
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
        shell("cd /bootstrap && python3 -m unittest discover -s server/legacy_migration -p 'test_*.py' -v");
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
    void actualCoordinatorImportsNonEmptyModulesAndReplaysWithoutMutation() throws Exception {
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

        // A real constraint at the late finance module must roll back earlier
        // masters, inventory and documents; only the failed run evidence remains.
        String baselineEmployees = scalar("SELECT count(*) FROM employees");
        execute("""
                CREATE FUNCTION synthetic_late_import_failure() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN RAISE EXCEPTION USING ERRCODE='UT701', MESSAGE='synthetic late module fault'; END; $$;
                CREATE TRIGGER synthetic_late_import_failure BEFORE INSERT ON finance_receipts
                FOR EACH ROW EXECUTE FUNCTION synthetic_late_import_failure();
                """);
        var lateFailure = coordinator();
        assertThat(lateFailure.getExitCode()).isNotZero();
        assertThat(lateFailure.getStderr()).withFailMessage(lateFailure.getStdout() + lateFailure.getStderr())
                .contains("UT701");
        assertThat(lateFailure.getStdout()).contains("Bootstrap module: migrate_finance.sql");
        assertBusinessImportRolledBack(baselineEmployees);
        execute("DROP TRIGGER synthetic_late_import_failure ON finance_receipts; DROP FUNCTION synthetic_late_import_failure();");

        execute("""
                CREATE FUNCTION synthetic_reconciliation_failure() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    IF NEW.metric = 'exact_authority_rows' THEN NEW.passed := false; END IF;
                    RETURN NEW;
                END; $$;
                CREATE TRIGGER synthetic_reconciliation_failure BEFORE INSERT ON legacy_migration_reconciliation_items
                FOR EACH ROW EXECUTE FUNCTION synthetic_reconciliation_failure();
                """);
        var reconciliationFailure = coordinator();
        assertThat(reconciliationFailure.getExitCode()).isNotZero();
        assertThat(reconciliationFailure.getStderr()).withFailMessage(reconciliationFailure.getStdout() + reconciliationFailure.getStderr())
                .contains("UT702");
        assertBusinessImportRolledBack(baselineEmployees);
        execute("DROP TRIGGER synthetic_reconciliation_failure ON legacy_migration_reconciliation_items; DROP FUNCTION synthetic_reconciliation_failure();");

        var imported = importWithCompetingHelper();
        assertThat(imported.getExitCode()).withFailMessage(imported.getStdout() + imported.getStderr()).isZero();
        assertThat(scalar("SELECT status || '|' || reconciliation_status FROM legacy_migration_runs WHERE status='SUCCESS' AND target='--bootstrap-all'"))
                .isEqualTo("SUCCESS|PASSED");
        assertThat(scalar("SELECT count(*) || '|' || count(*) FILTER (WHERE NOT item.passed) FROM legacy_migration_reconciliation_items item JOIN legacy_migration_runs run USING(run_id) WHERE run.target='--bootstrap-all'"))
                .isEqualTo("23|0");
        assertThat(scalar("SELECT reconciliation_summary->>'moduleRowChecksPassed' FROM legacy_migration_runs WHERE status='SUCCESS' AND target='--bootstrap-all'")).isEqualTo("true");
        for (String table : List.of("goods", "purchase_order_items", "stock_document_items", "stock_balances",
                "sales_order_items", "subcontract_order_items", "production_plan_items", "finance_receipts")) {
            assertThat(Long.parseLong(scalar("SELECT count(*) FROM " + table))).as(table).isPositive();
        }
        String identity = scalar("SELECT md5(string_agg(id::text || ':' || legacy_id::text, ',' ORDER BY id)) FROM goods");
        assertThat(scalar("""
                SELECT (r.qty=10 AND r.amount_original=25 AND o.qty=10 AND o.amount_original=25
                    AND request.qty=10 AND g.legacy_id=900102)::text
                FROM purchase_receipt_items r JOIN purchase_order_items o ON o.id=r.order_item_id
                JOIN purchase_request_items request ON request.id=o.request_item_id JOIN goods g ON g.id=r.goods_id
                WHERE r.legacy_id=901006
                """)).isEqualTo("true");
        assertThat(scalar("""
                SELECT bool_and((g.legacy_id=900102 AND b.qty=6 AND b.amount_local=15)
                    OR (g.legacy_id=900101 AND b.qty=3 AND b.amount_local=12)
                    OR (g.legacy_id=900103 AND b.qty=4 AND b.amount_local=12))::text
                FROM stock_balances b JOIN goods g ON g.id=b.goods_id JOIN warehouses w ON w.id=b.warehouse_id
                WHERE w.legacy_id=900201
                """)).isEqualTo("true");
        assertThat(scalar("""
                SELECT (amount_original=20 AND amount_settled=8 AND amount_balance=12)::text
                FROM ar_ap_ledger WHERE legacy_source='M_in' AND legacy_id=906003
                """)).isEqualTo("true");
        assertThat(scalar("""
                SELECT (amount_original=8 AND amount_local=8 AND receipt_kind='LEGACY_UNCLASSIFIED'
                    AND settlement_authority_version=0 AND legacy_import_run_id IS NOT NULL)::text
                FROM finance_receipts WHERE legacy_id=906002
                """)).isEqualTo("true");
        assertThat(scalar("""
                SELECT (amount_original=2 AND amount_local=0 AND exchange_rate=0
                    AND legacy_import_run_id IS NOT NULL)::text FROM finance_expenses WHERE legacy_id=907003
                """)).isEqualTo("true");
        assertThat(scalar("""
                SELECT (count(*)=2 AND sum(amount_original)=2 AND sum(amount_local)=0
                    AND array_agg(line_no ORDER BY legacy_id)=ARRAY[1,2])::text
                FROM finance_expense_items WHERE legacy_id IN(907004,907005)
                """)).isEqualTo("true");
        assertThat(scalar("SELECT (amount_original=5 AND amount_local=5)::text FROM finance_payments WHERE legacy_id=907002"))
                .isEqualTo("true");
        assertThat(scalar("SELECT (amount_original=20 AND amount_local=20)::text FROM finance_other_incomes WHERE legacy_id=907006"))
                .isEqualTo("true");
        assertThat(scalar("SELECT (balance_current=15 AND receipts_total=20 AND payments_total=5)::text FROM accounts WHERE legacy_id=907001"))
                .isEqualTo("true");
        assertThat(scalar("""
                SELECT (count(*)=4 AND bool_and(entry_kind='LEGACY_SNAPSHOT')
                    AND sum(in_amount)=28 AND sum(out_amount)=5)::text
                FROM finance_reconciliations WHERE legacy_id IS NOT NULL
                """)).isEqualTo("true");
        assertThat(scalar("SELECT count(*) FROM finance_receipt_lines")).isEqualTo("0");
        assertThat(scalar("SELECT count(*) FROM finance_payment_lines")).isEqualTo("0");
        assertThat(scalar("SELECT count(*) FROM gl_vouchers")).isEqualTo("0");
        assertThat(scalar("SELECT warehouse_work_status || '|' || finance_gate_version FROM sales_shipments WHERE legacy_id=903003"))
                .isEqualTo("SHIPPED|0");
        assertThat(scalar("SELECT count(*) FROM sales_shipment_finance_release_events")).isEqualTo("0");
        assertThat(scalar("SELECT count(*) FROM production_daily_reports")).isEqualTo("0");
        assertThat(scalar("SELECT count(*) FROM goods WHERE stock_place IS NOT NULL")).isEqualTo("0");
        String history = scalar("SELECT count(*) FROM audit_log");
        var replay = coordinator();
        assertThat(replay.getExitCode()).withFailMessage(replay.getStdout() + replay.getStderr()).isZero();
        assertThat(replay.getStdout()).contains("返回原回执");
        assertThat(scalar("SELECT count(*) FROM legacy_migration_runs")).isEqualTo(Long.toString(Long.parseLong(before) + 3));
        assertThat(scalar("SELECT md5(string_agg(id::text || ':' || legacy_id::text, ',' ORDER BY id)) FROM goods")).isEqualTo(identity);
        assertThat(scalar("SELECT count(*) FROM audit_log")).isEqualTo(history);
        shell("test ! -d /tmp/uten-legacy-migration.lock && test -z \"$(find /tmp -maxdepth 1 -name 'uten-legacy-keys.*.sql' -print -quit)\"");
        importedOpeningAcceptsNativeSettlementWithoutRepostingHistory();
        historicalReferenceAndOrphanBomVariant();
        stockOnlyReferencesKeepColorAndWeightDimensions();
        malformedSourceAndCryptoFailuresDoNotLeakSensitiveValues();
    }

    private static void importedOpeningAcceptsNativeSettlementWithoutRepostingHistory() {
        // Start the actual application on the same successfully imported DB,
        // using only the already-frozen schema candidate and isolated test keys.
        try (var context = new org.springframework.boot.builder.SpringApplicationBuilder(
                com.uten.imp.UtenImpApplication.class).run(
                "--spring.profiles.active=dev", "--server.address=127.0.0.1", "--server.port=0",
                "--spring.datasource.url=" + jdbcUrl(),
                "--spring.datasource.username=" + postgres.getUsername(),
                "--spring.datasource.password=" + postgres.getPassword(),
                "--spring.flyway.locations=filesystem:" + candidate.resolve("server/src/main/resources/db/migration"),
                "--uten.audit.retention.enabled=false", "--uten.reporting.materialized-view-refresh.enabled=false",
                "--uten.policy-intelligence.enabled=false", "--uten.features.goods-owner-scope-enabled=false",
                "--uten.jwt.secret=bootstrap-native-test-jwt-secret-0123456789-test-only",
                "--uten.crypto.pgp-master-key=synthetic-test-only-pgp-material-0001",
                "--uten.crypto.hmac-key=synthetic-test-only-hmac-material-0001",
                "--uten.crypto.pgp-key-version=test-v1",
                "--uten.bootstrap.admin-login=bootstrap-native-test-admin",
                "--uten.bootstrap.admin-password=BootstrapNativeTest-1!")) {
            com.uten.imp.businesschain.LegacyFinanceNativeSettlementAcceptance.verify(context,
                    context.getBean(org.springframework.jdbc.core.JdbcTemplate.class));
        } finally {
            org.springframework.security.core.context.SecurityContextHolder.clearContext();
        }
    }

    private static void historicalReferenceAndOrphanBomVariant() throws Exception {
        shell("createdb -U uten -T legacy_bootstrap_template legacy_bootstrap_history");
        activeDatabase = "legacy_bootstrap_history";
        generateFixture("historical-references.json", "orphan-bom.json", "opening-ambiguity.json", "purchase-missing-masters.json");
        var imported = coordinator();
        assertThat(imported.getExitCode()).withFailMessage(imported.getStdout() + imported.getStderr()).isZero();
        assertThat(scalar("SELECT count(*) FROM goods WHERE legacy_id=910101 AND auto_created AND code='LEGACY-G-910101'"))
                .isEqualTo("1");
        assertThat(scalar("SELECT count(*) FROM goods WHERE legacy_id IN (919998,919999)")).isEqualTo("0");
        assertThat(scalar("SELECT count(*) FROM goods_bom_items WHERE legacy_id IN (900902,900903,900904)"))
                .isEqualTo("0");
        assertThat(scalar("SELECT jsonb_array_length(reconciliation_summary->'historicalAnchors') FROM legacy_migration_runs WHERE target='--bootstrap-all'"))
                .isEqualTo("8");
        assertThat(scalar("SELECT jsonb_array_length(reconciliation_summary->'bomExclusions') FROM legacy_migration_runs WHERE target='--bootstrap-all'"))
                .isEqualTo("3");
        assertThat(scalar("""
                SELECT (balance.qty=2 AND balance.amount_local=14 AND NOT warehouse.is_accountable)::text
                FROM stock_balances balance JOIN goods ON goods.id=balance.goods_id
                JOIN warehouses warehouse ON warehouse.id=balance.warehouse_id JOIN colors color ON color.id=balance.color_id
                WHERE goods.legacy_id=910101 AND warehouse.legacy_id=910201 AND color.legacy_id=910401
                """)).isEqualTo("true");
        assertThat(scalar("SELECT count(*) FROM clients WHERE legacy_id=910501 AND status='禁用'"))
                .isEqualTo("1");
        assertThat(scalar("SELECT count(*) FROM suppliers WHERE legacy_id=910601 AND status='禁用'"))
                .isEqualTo("1");
        assertThat(scalar("""
                SELECT (source_doc_type='LEGACY_OPENING' AND source_doc_id IS NULL
                    AND open_item_kind='LEGACY_UNVERIFIED' AND amount_original_local=25 AND amount_balance=25
                    AND legacy_source_resolution->>'status'='AMBIGUOUS_SOURCE'
                    AND jsonb_array_length(legacy_source_resolution->'candidates')=2)::text
                FROM ar_ap_ledger WHERE legacy_source='M_out' AND legacy_id=906004
                """)).isEqualTo("true");
        assertThat(scalar("""
                SELECT (source_doc_type='LEGACY_OPENING' AND open_item_kind='LEGACY_UNVERIFIED'
                    AND amount_original_local=0 AND amount_settled=8 AND amount_balance=-8)::text
                FROM ar_ap_ledger WHERE legacy_source='M_in' AND legacy_id=908005
                """)).isEqualTo("true");
        assertThat(scalar("""
                SELECT (source_doc_type='LEGACY_OPENING' AND source_doc_id IS NULL AND amount_original IS NULL
                    AND amount_received_original IS NULL AND amount_balance_original IS NULL
                    AND amount_original_local=5 AND amount_balance=5 AND exchange_rate=0)::text
                FROM ar_ap_ledger WHERE legacy_source='M_in' AND legacy_id=908006
                """)).isEqualTo("true");
        assertThat(scalar("""
                SELECT (receipt.amount_original=6 AND receipt.amount_local=12 AND receipt.unit_rate=1
                    AND goods.legacy_id=930101 AND goods.auto_created AND goods.status='禁用'
                    AND supplier.legacy_id=930601 AND supplier.status='禁用')::text
                FROM purchase_receipt_items receipt JOIN purchase_receipts header ON header.id=receipt.receipt_id
                JOIN goods ON goods.id=receipt.goods_id JOIN suppliers supplier ON supplier.id=header.supplier_id
                WHERE receipt.legacy_id=930004
                """)).isEqualTo("true");
        assertThat(scalar("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_no='CJ-SYN-MISSING'")).isEqualTo("0");
        assertThat(scalar("SELECT count(*) FROM stock_movements WHERE source_doc_id=(SELECT id FROM purchase_receipts WHERE legacy_id=930003)"))
                .isEqualTo("0");
        String oldOpening = scalar("SELECT to_jsonb(ledger)::text FROM ar_ap_ledger ledger WHERE legacy_id=908005 AND legacy_source='M_in'");
        for (String change : List.of("legacy_import_run_id=NULL", "source_doc_type='SALES_SHIPMENT'",
                "amount_original_local=99", "legacy_source_resolution='{}'::jsonb")) {
            assertThatThrownBy(() -> execute("UPDATE ar_ap_ledger SET " + change + " WHERE legacy_id=908005 AND legacy_source='M_in'"))
                    .isInstanceOf(java.sql.SQLException.class);
        }
        assertThatThrownBy(() -> execute("""
                INSERT INTO ar_ap_ledger(direction,source_doc_type,bill_no,bill_date,amount_original,
                    amount_original_local,amount_settled,amount_balance)
                VALUES('AR','LEGACY_OPENING','SYN-FORGED-OPENING','2025-01-02',10,10,0,10)
                """)).isInstanceOf(java.sql.SQLException.class);
        assertThat(scalar("SELECT to_jsonb(ledger)::text FROM ar_ap_ledger ledger WHERE legacy_id=908005 AND legacy_source='M_in'"))
                .isEqualTo(oldOpening);
        assertThat(coordinator().getExitCode()).isZero();
    }

    private static org.testcontainers.containers.Container.ExecResult importWithCompetingHelper() throws Exception {
        String host = postgres.getContainerInfo().getNetworkSettings().getNetworks().values().iterator().next().getIpAddress();
        try (var helper = new GenericContainer<>(DockerImageName.parse(postgres.getDockerImageName()))
                .withEnv("PGHOST", host).withEnv("PGPASSWORD", postgres.getPassword()).withCommand("sleep", "infinity")) {
            helper.start();
            execute("""
                    CREATE FUNCTION synthetic_claim_barrier() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
                        IF NEW.target='--bootstrap-all' THEN PERFORM pg_advisory_xact_lock(91624001); END IF;
                        RETURN NEW;
                    END; $$;
                    CREATE TRIGGER synthetic_claim_barrier BEFORE INSERT ON legacy_migration_runs
                    FOR EACH ROW EXECUTE FUNCTION synthetic_claim_barrier();
                    CREATE FUNCTION synthetic_business_barrier() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
                        PERFORM pg_advisory_xact_lock(91624002); RETURN NEW;
                    END; $$;
                    CREATE TRIGGER synthetic_business_barrier BEFORE INSERT ON finance_receipts
                    FOR EACH ROW EXECUTE FUNCTION synthetic_business_barrier();
                    """);
            try (var claimBarrier = DriverManager.getConnection(jdbcUrl(), postgres.getUsername(), postgres.getPassword());
                 var businessBarrier = DriverManager.getConnection(jdbcUrl(), postgres.getUsername(), postgres.getPassword());
                 var executor = Executors.newVirtualThreadPerTaskExecutor()) {
                claimBarrier.setAutoCommit(false);
                businessBarrier.setAutoCommit(false);
                claimBarrier.createStatement().execute("SELECT pg_advisory_xact_lock(91624001)");
                businessBarrier.createStatement().execute("SELECT pg_advisory_xact_lock(91624002)");
                var first = executor.submit(() -> coordinator());
                try {
                    for (int barrierKey : List.of(91624001, 91624002)) {
                        long deadline = System.nanoTime() + TimeUnit.MINUTES.toNanos(3);
                        boolean blocked = false;
                        while (System.nanoTime() < deadline && !first.isDone()) {
                            blocked = "true".equals(scalar("SELECT EXISTS(SELECT 1 FROM pg_locks WHERE locktype='advisory' AND database=(SELECT oid FROM pg_database WHERE datname=current_database()) AND objid=" + barrierKey + " AND NOT granted)::text"));
                            if (blocked) break;
                            Thread.sleep(50);
                        }
                        if (first.isDone()) return first.get();
                        assertThat(blocked).as("first helper reached advisory barrier " + barrierKey).isTrue();
                        var second = coordinator("PG_CONTAINER=" + helper.getContainerId());
                        assertThat(second.getExitCode()).withFailMessage(second.getStdout() + second.getStderr()).isNotZero();
                        assertThat(second.getStderr()).contains("UT703");
                        shell("test -d /tmp/uten-legacy-migration.lock");
                        assertThat(helper.execInContainer("test", "!", "-d", "/tmp/uten-legacy-migration.lock").getExitCode()).isZero();
                        if (barrierKey == 91624001) claimBarrier.commit();
                        else businessBarrier.commit();
                    }
                    return first.get(3, TimeUnit.MINUTES);
                } finally {
                    claimBarrier.rollback();
                    businessBarrier.rollback();
                }
            } finally {
                execute("DROP TRIGGER synthetic_claim_barrier ON legacy_migration_runs; DROP FUNCTION synthetic_claim_barrier(); DROP TRIGGER synthetic_business_barrier ON finance_receipts; DROP FUNCTION synthetic_business_barrier();");
            }
        }
    }

    private static void generateFixture(String... variants) throws Exception {
        String fixtures = ROOT + "/server/src/test/resources/legacy-bootstrap-fixture";
        var command = new ArrayList<>(List.of("python3", fixtures + "/generate_fixture.py", ROOT, fixtures + "/rows.json",
                fixtures + "/variants/finance-facts.json"));
        for (String variant : variants) command.add(fixtures + "/variants/" + variant);
        var generated = postgres.execInContainer(command.toArray(String[]::new));
        assertThat(generated.getExitCode()).withFailMessage(generated.getStdout() + generated.getStderr()).isZero();
        var digest = postgres.execInContainer("sha256sum", ROOT + "/synthetic-source-snapshot.json");
        assertThat(digest.getExitCode()).isZero();
        sourceBackupDigest = digest.getStdout().split(" ")[0];
    }

    private static void stockOnlyReferencesKeepColorAndWeightDimensions() throws Exception {
        shell("createdb -U uten -T legacy_bootstrap_template legacy_bootstrap_stock_only");
        activeDatabase = "legacy_bootstrap_stock_only";
        generateFixture("stock-only.json");
        var imported = coordinator();
        assertThat(imported.getExitCode()).withFailMessage(imported.getStdout() + imported.getStderr()).isZero();
        assertThat(scalar("""
                SELECT count(*) || '|' || count(*) FILTER (WHERE balance.color_id IS NULL)
                FROM stock_balances balance JOIN goods ON goods.id=balance.goods_id WHERE goods.legacy_id=920101
                """)).isEqualTo("2|1");
        assertThat(scalar("""
                SELECT (sum(balance.qty)=8 AND sum(balance.amount_local)=26.5 AND sum(balance.weight)=3.7)::text
                FROM stock_balances balance JOIN goods ON goods.id=balance.goods_id WHERE goods.legacy_id=920101
                """)).isEqualTo("true");
        assertThat(scalar("""
                SELECT count(*) FROM stock_movements movement JOIN goods ON goods.id=movement.goods_id WHERE goods.legacy_id=920101
                """)).isEqualTo("0");
    }

    private static void malformedSourceAndCryptoFailuresDoNotLeakSensitiveValues() throws Exception {
        shell("createdb -U uten -T legacy_bootstrap_template legacy_bootstrap_private_copy");
        activeDatabase = "legacy_bootstrap_private_copy";
        String copyBaselineEmployees = scalar("SELECT count(*) FROM employees");
        String fixtures = ROOT + "/server/src/test/resources/legacy-bootstrap-fixture";
        put("/tmp/private-copy-variant.json", """
                {"goods.csv":[{"legacy_id":930101,"code":"SYN-PRIVATE-COPY","name":"synthetic",
                    "init_stock":"PII_CANARY_PRIVATE_IMPORT_930101","status":"使用"}]}
                """);
        var generated = postgres.execInContainer("python3", fixtures + "/generate_fixture.py", ROOT,
                fixtures + "/rows.json", "/tmp/private-copy-variant.json");
        assertThat(generated.getExitCode()).withFailMessage(generated.getStderr()).isZero();
        sourceBackupDigest = postgres.execInContainer("sha256sum", ROOT + "/synthetic-source-snapshot.json").getStdout().split(" ")[0];
        var copyFailure = coordinator();
        assertThat(copyFailure.getExitCode()).isNotZero();
        assertThat(copyFailure.getStderr()).contains("22P02");
        assertThat(copyFailure.getStdout()).contains("Bootstrap module: migrate_goods_data.sql");
        assertThat(copyFailure.getStdout() + copyFailure.getStderr() + postgres.getLogs())
                .doesNotContain("PII_CANARY_PRIVATE_IMPORT_930101");
        assertBusinessImportRolledBack(copyBaselineEmployees);

        shell("createdb -U uten -T legacy_bootstrap_template legacy_bootstrap_private_crypto");
        activeDatabase = "legacy_bootstrap_private_crypto";
        String cryptoBaselineEmployees = scalar("SELECT count(*) FROM employees");
        generateFixture();
        // Isolated test-only schema fault: PostgreSQL's failed statement contains
        // the expanded secret literal, so client-only redaction would be insufficient.
        execute("ALTER FUNCTION public.pgp_sym_encrypt(text,text) RENAME TO synthetic_disabled_encrypt;");
        put(ROOT + "/server/.env", "UTEN_PGP_MASTER_KEY=TEST_KEY_CANARY_PRIVATE_IMPORT_930102\nUTEN_HMAC_KEY=synthetic-test-only-hmac-material-0001\nUTEN_PGP_KEY_VERSION=test-v1\n");
        var cryptoFailure = coordinator();
        assertThat(cryptoFailure.getExitCode()).isNotZero();
        assertThat(cryptoFailure.getStderr()).contains("42883");
        assertThat(cryptoFailure.getStdout()).contains("Bootstrap module: migrate_hr_workers.sql");
        assertThat(cryptoFailure.getStdout() + cryptoFailure.getStderr() + postgres.getLogs())
                .doesNotContain("TEST_KEY_CANARY_PRIVATE_IMPORT_930102");
        assertBusinessImportRolledBack(cryptoBaselineEmployees);
    }

    private static org.testcontainers.containers.Container.ExecResult coordinator(String... overrides) throws Exception {
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
        command.addAll(List.of("bash", ROOT + "/server/legacy_migration/migrate.sh", "--bootstrap-all", "--confirm-destructive"));
        return postgres.execInContainer(command.toArray(String[]::new));
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

    private static void execute(String sql) throws Exception {
        try (var connection = DriverManager.getConnection(jdbcUrl(), postgres.getUsername(), postgres.getPassword());
             var statement = connection.createStatement()) {
            statement.execute(sql);
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
        return Integer.parseInt(name.substring(1, name.indexOf("__")));
    }
}
