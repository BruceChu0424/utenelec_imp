package com.uten.imp.features.master.paymentstyle;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PaymentStyleReferenceGuardMigrationContractTest {

    private static final Set<String> EXPECTED_UUID_REFERENCES = Set.of(
            "accounts.style_id",
            "deferred_expenses.accumulated_style_snapshot_id",
            "deferred_expenses.clearing_style_snapshot_id",
            "deferred_expenses.cost_style_snapshot_id",
            "deferred_expenses.expense_style_id",
            "deferred_expenses.expense_style_snapshot_id",
            "expense_claims.payment_expense_style_id",
            "finance_asset_books.accumulated_style_id",
            "finance_asset_books.clearing_style_id",
            "finance_asset_books.cost_style_id",
            "finance_asset_books.expense_style_id",
            "finance_asset_categories.accumulated_style_id",
            "finance_asset_categories.clearing_style_id",
            "finance_asset_categories.cost_style_id",
            "finance_asset_categories.expense_style_id",
            "finance_asset_posting_lines.accumulated_style_id",
            "finance_asset_posting_lines.clearing_style_id",
            "finance_asset_posting_lines.cost_style_id",
            "finance_asset_posting_lines.expense_style_id",
            "finance_deferral_schedule_versions.clearing_style_id",
            "finance_deferral_schedule_versions.cost_style_id",
            "finance_deferral_schedule_versions.expense_style_id",
            "finance_expense_items.expense_style_id",
            "finance_other_income_items.income_style_id",
            "finance_receipts.other_fee_style_id",
            "fixed_assets.accumulated_style_snapshot_id",
            "fixed_assets.clearing_style_snapshot_id",
            "fixed_assets.cost_style_snapshot_id",
            "fixed_assets.expense_style_id",
            "fixed_assets.expense_style_snapshot_id",
            "gl_entries.style_id",
            "system_posting_style_roles.style_id");

    private static final Pattern CREATE_TABLE = Pattern.compile(
            "^CREATE\\s+TABLE(?:\\s+IF\\s+NOT\\s+EXISTS)?\\s+([a-z_][a-z0-9_]*)",
            Pattern.CASE_INSENSITIVE);
    private static final Pattern ALTER_TABLE = Pattern.compile(
            "^ALTER\\s+TABLE(?:\\s+IF\\s+EXISTS)?\\s+([a-z_][a-z0-9_]*)",
            Pattern.CASE_INSENSITIVE);
    private static final Pattern REFERENCE_COLUMN = Pattern.compile(
            "^(?:ADD\\s+COLUMN(?:\\s+IF\\s+NOT\\s+EXISTS)?\\s+)?"
                    + "([a-z_][a-z0-9_]*)\\s+.*REFERENCES\\s+payment_styles\\s*\\(",
            Pattern.CASE_INSENSITIVE);
    private static final Pattern INLINE_ALTER_REFERENCE = Pattern.compile(
            "^ALTER\\s+TABLE(?:\\s+IF\\s+EXISTS)?\\s+([a-z_][a-z0-9_]*)\\s+"
                    + "ADD\\s+COLUMN(?:\\s+IF\\s+NOT\\s+EXISTS)?\\s+"
                    + "([a-z_][a-z0-9_]*)\\s+.*REFERENCES\\s+payment_styles\\s*\\(",
            Pattern.CASE_INSENSITIVE);
    private static final Pattern TABLE_LEVEL_FOREIGN_KEY_REFERENCE = Pattern.compile(
            "^(?:ADD\\s+CONSTRAINT\\s+[a-z_][a-z0-9_]*\\s+)?"
                    + "FOREIGN\\s+KEY\\s*\\(\\s*([a-z_][a-z0-9_]*)\\s*\\)"
                    + "\\s+REFERENCES\\s+payment_styles\\s*\\(",
            Pattern.CASE_INSENSITIVE);
    private static final Pattern V265_GUARD = Pattern.compile(
            "\\('trg_psref_[^']+'\\s*,\\s*'([a-z_][a-z0-9_]*)'\\s*,\\s*"
                    + "'([a-z_][a-z0-9_]*)'",
            Pattern.CASE_INSENSITIVE);
    private static final Pattern EXPLICIT_GUARD = Pattern.compile(
            "CREATE\\s+TRIGGER\\s+[^\\s]+.*?ON\\s+([a-z_][a-z0-9_]*).*?"
                    + "fn_guard_payment_style_reference\\s*\\(\\s*'([a-z_][a-z0-9_]*)'",
            Pattern.CASE_INSENSITIVE | Pattern.DOTALL);
    private static final Pattern TRANSACTION_LOCAL_IMPORT_MODE = Pattern.compile(
            "set_config\\s*\\(\\s*'uten\\.payment_style_reference_import'\\s*,\\s*"
                    + "'legacy-finance-v1'\\s*,\\s*true\\s*\\)",
            Pattern.CASE_INSENSITIVE | Pattern.DOTALL);

    @Test
    void migrationsGuardEveryRealUuidReferenceAndTheLegacyAccountReference() throws Exception {
        Set<String> schemaReferences = findPaymentStyleUuidReferences();
        assertEquals(
                EXPECTED_UUID_REFERENCES,
                schemaReferences,
                "the contract list must track every non-hierarchy UUID FK to payment_styles");

        String v265 = Files.readString(serverPath(
                "src/main/resources/db/migration/V265__payment_style_reference_guards.sql"));
        String v267 = Files.readString(serverPath(
                "src/main/resources/db/migration/V267__account_payment_style_uuid.sql"));
        String v278 = Files.readString(serverPath(
                "src/main/resources/db/migration/V278__system_posting_style_uuid_roles.sql"));
        Set<String> guardedReferences = new TreeSet<>();
        Matcher guards = V265_GUARD.matcher(v265);
        while (guards.find()) {
            guardedReferences.add(guards.group(1) + "." + guards.group(2));
        }
        Matcher explicitGuards = EXPLICIT_GUARD.matcher(v267);
        while (explicitGuards.find()) {
            guardedReferences.add(explicitGuards.group(1) + "." + explicitGuards.group(2));
        }
        assertTrue(v278.contains("CREATE TRIGGER trg_system_posting_style_role_guard")
                        && v278.contains("system posting role requires an active payment style UUID")
                        && v278.contains("system posting role payment style category mismatch"),
                "V278 must validate its persisted system-posting style UUID relation");
        guardedReferences.add("system_posting_style_roles.style_id");

        Set<String> expectedGuards = new TreeSet<>(EXPECTED_UUID_REFERENCES);
        expectedGuards.add("accounts.style_legacy_id");
        assertEquals(
                expectedGuards,
                guardedReferences,
                "payment-style guard migrations must cover every real UUID reference plus the legacy account shadow");

        assertTrue(v267.contains(
                        "fn_guard_payment_style_reference(\n"
                                + "        'style_id', 'ACCOUNT', 'true', 'true', 'false', 'false')"),
                "V267 must pass the UUID account column and guard flags in the V265 function's argument order");
        assertTrue(v267.contains("CREATE TRIGGER trg_psref_accounts_style_uuid"),
                "V267 must install a separately named UUID guard");
        assertTrue(!v267.contains("DROP TRIGGER IF EXISTS trg_psref_accounts_style"),
                "V267 must retain V265's guard for the still-readable legacy account shadow");

        int lock = v265.indexOf("PERFORM pg_advisory_xact_lock");
        int importBypass = v265.indexOf(
                "current_setting('uten.payment_style_reference_import', TRUE)");
        assertTrue(lock >= 0 && importBypass > lock,
                "even legacy import mode must acquire the hierarchy lock before bypassing checks");
        assertTrue(v265.contains("BEFORE INSERT OR UPDATE ON %I"),
                "reference validation must be an immediate BEFORE trigger");
    }

    @Test
    void legacyFinanceImportUsesTransactionLocalModeAndReconcilesBeforeCommit()
            throws Exception {
        String sql = Files.readString(serverPath("legacy_migration/migrate_finance.sql"));
        Matcher importMode = TRANSACTION_LOCAL_IMPORT_MODE.matcher(sql);
        assertTrue(importMode.find(),
                "legacy-finance-v1 must be set with set_config(..., true) transaction scope");

        int begin = sql.indexOf("BEGIN;");
        int reconciliation = sql.indexOf(
                "-- The import mode only relaxes runtime active/leaf rules.");
        int commit = sql.indexOf("COMMIT;", reconciliation);
        assertTrue(begin >= 0 && begin < importMode.start());
        assertTrue(importMode.end() < reconciliation && reconciliation < commit,
                "existence/category reconciliation must run after import mode and before COMMIT");

        String beforeCommit = normalizeWhitespace(sql.substring(reconciliation, commit));
        assertLegacyReconciliation(
                beforeCommit, "accounts", "a", "legacy_id", "style_legacy_id", "ACCOUNT");
        assertLegacyReconciliation(
                beforeCommit, "finance_receipts", "r", "id", "other_fee_style_id", "EXPENSE");
        assertLegacyReconciliation(
                beforeCommit, "finance_expense_items", "i", "id", "expense_style_id", "EXPENSE");
        assertLegacyReconciliation(
                beforeCommit, "finance_other_income_items", "i", "id", "income_style_id", "INCOME");
        assertTrue(beforeCommit.contains(
                "RAISE EXCEPTION 'finance migration payment-style mapping violations: %'"));

        String afterReconciliation = sql.substring(reconciliation, commit);
        assertTrue(Pattern.compile(
                        "set_config\\s*\\(\\s*'uten\\.payment_style_reference_import'\\s*,"
                                + "\\s*'off'\\s*,\\s*true\\s*\\)",
                        Pattern.CASE_INSENSITIVE | Pattern.DOTALL)
                .matcher(afterReconciliation)
                .find(), "the transaction-local import marker must be cleared before COMMIT");
    }

    private static Set<String> findPaymentStyleUuidReferences() throws IOException {
        Path migrationDirectory = serverPath("src/main/resources/db/migration");
        List<Path> migrations;
        try (var paths = Files.list(migrationDirectory)) {
            migrations = paths
                    .filter(path -> path.getFileName().toString().matches("V\\d+__.*\\.sql"))
                    .sorted()
                    .toList();
        }

        Set<String> references = new TreeSet<>();
        for (Path migration : migrations) {
            collectPaymentStyleUuidReferences(Files.readAllLines(migration), references);
        }
        return references;
    }

    private static void collectPaymentStyleUuidReferences(
            List<String> lines,
            Set<String> references) {
        String createTable = null;
        String alterTable = null;
        for (String rawLine : lines) {
            String line = rawLine.strip();
            if (line.isEmpty() || line.startsWith("--")) continue;

            Matcher create = CREATE_TABLE.matcher(line);
            if (create.find()) createTable = create.group(1).toLowerCase(Locale.ROOT);

            Matcher alter = ALTER_TABLE.matcher(line);
            if (alter.find()) alterTable = alter.group(1).toLowerCase(Locale.ROOT);

            if (line.toLowerCase(Locale.ROOT).contains("references payment_styles")) {
                Matcher inlineAlter = INLINE_ALTER_REFERENCE.matcher(line);
                String table;
                String column;
                if (inlineAlter.find()) {
                    table = inlineAlter.group(1).toLowerCase(Locale.ROOT);
                    column = inlineAlter.group(2).toLowerCase(Locale.ROOT);
                } else {
                    Matcher tableLevelForeignKey = TABLE_LEVEL_FOREIGN_KEY_REFERENCE.matcher(line);
                    if (tableLevelForeignKey.find()) {
                        table = alterTable;
                        column = tableLevelForeignKey.group(1).toLowerCase(Locale.ROOT);
                    } else {
                        Matcher referenceColumn = REFERENCE_COLUMN.matcher(line);
                        assertTrue(referenceColumn.find(),
                                () -> "cannot determine payment_styles reference column from: " + line);
                        table = createTable != null ? createTable : alterTable;
                        column = referenceColumn.group(1).toLowerCase(Locale.ROOT);
                    }
                }
                assertTrue(table != null,
                        () -> "cannot determine payment_styles reference table from: " + line);
                if (!"payment_styles".equals(table)) {
                    references.add(table + "." + column);
                }
            }

            if (createTable != null && line.matches("^\\);.*")) createTable = null;
            if (alterTable != null && line.contains(";")) alterTable = null;
        }
    }

    private static void assertLegacyReconciliation(
            String sql,
            String table,
            String alias,
            String styleJoinColumn,
            String referenceColumn,
            String expectedCategory) {
        assertTrue(sql.contains(
                        "FROM " + table + " " + alias
                                + " LEFT JOIN payment_styles s ON s." + styleJoinColumn
                                + " = " + alias + "." + referenceColumn),
                () -> "missing existence reconciliation for " + table + "." + referenceColumn);
        assertTrue(sql.contains(
                        alias + "." + referenceColumn
                                + " IS NOT NULL AND (s.id IS NULL OR s.category <> '"
                                + expectedCategory + "')"),
                () -> "missing " + expectedCategory + " reconciliation for "
                        + table + "." + referenceColumn);
    }

    private static String normalizeWhitespace(String value) {
        return value.replaceAll("\\s+", " ").trim();
    }

    private static Path serverPath(String relative) {
        Path direct = Path.of(relative);
        if (Files.exists(direct)) return direct;

        Path fromRepositoryRoot = Path.of("server").resolve(relative);
        assertTrue(Files.exists(fromRepositoryRoot),
                () -> "server test resource not found: " + relative);
        return fromRepositoryRoot;
    }
}
