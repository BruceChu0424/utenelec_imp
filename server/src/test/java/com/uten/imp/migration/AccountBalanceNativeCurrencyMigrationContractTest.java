package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class AccountBalanceNativeCurrencyMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V401__account_balance_native_currency_basis.sql");
    private static final Path SERVICE = Path.of(
            "src/main/java/com/uten/imp/features/finance/accountbalance/"
                    + "AccountBalanceAdjustmentService.java");

    @Test
    void migrationPreservesLegacyRowsAndRequiresAnExplicitLocalAmountBasis() throws Exception {
        String source = Files.readString(MIGRATION);

        assertThat(source)
                .contains("ADD COLUMN local_amount_basis")
                .contains("'LEGACY_REFERENCE_RATE'")
                .contains("'BASE_CURRENCY_IDENTITY'")
                .contains("'FINANCE_EXPLICIT_LOCAL'")
                .contains("'NO_CHANGE'")
                .contains("ALTER COLUMN exchange_rate_snapshot DROP NOT NULL")
                .contains("DROP CONSTRAINT account_balance_adjustment_items_rate_chk")
                .contains("DROP CONSTRAINT account_balance_adjustment_items_local_chk")
                .contains("VALIDATE CONSTRAINT account_balance_adjustment_items_local_basis_chk")
                .contains("VALIDATE CONSTRAINT account_balance_adjustment_items_local_evidence_chk")
                .doesNotContain("UPDATE account_balance_adjustment_items");
    }

    @Test
    void applicationNeverUsesTheMutableCurrencyMasterRateForBalanceReconciliation()
            throws Exception {
        String source = Files.readString(SERVICE);

        assertThat(source)
                .doesNotContain("currency.exchange_rate")
                .doesNotContain("外币账户缺少有效参考汇率")
                .contains("requested.localDelta()")
                .contains("FINANCE_EXPLICIT_LOCAL")
                .contains("BASE_CURRENCY_IDENTITY")
                .contains("NO_CHANGE");
    }

    @Test
    void forwardGuardsRejectNewLegacyBasisAndBindBaseCurrencyToItsUuid()
            throws Exception {
        String v402 = Files.readString(Path.of(
                "src/main/resources/db/migration/"
                        + "V402__guard_legacy_balance_adjustment_basis.sql"));
        String v403 = Files.readString(Path.of(
                "src/main/resources/db/migration/"
                        + "V403__functional_currency_uuid_authority.sql"));
        String v404 = Files.readString(Path.of(
                "src/main/resources/db/migration/"
                        + "V404__account_balance_currency_match_guard.sql"));
        String v405 = Files.readString(Path.of(
                "src/main/resources/db/migration/"
                        + "V405__functional_currency_primary_key_guard.sql"));

        assertThat(v402)
                .contains("BEFORE INSERT ON account_balance_adjustment_items")
                .contains("LEGACY_REFERENCE_RATE is historical V400 evidence");
        assertThat(v403)
                .contains("ADD COLUMN is_base_currency BOOLEAN NOT NULL DEFAULT FALSE")
                .contains("WHERE legacy_id = 1")
                .contains("uq_currencies_single_base_currency")
                .contains("trg_guard_base_currency_authority")
                .contains("functional currency UUID authority is immutable")
                .contains("functional-currency balance adjustment must use BASE_CURRENCY_IDENTITY")
                .contains("foreign-currency balance adjustment must use FINANCE_EXPLICIT_LOCAL");
        assertThat(v404)
                .contains("v_account_currency IS DISTINCT FROM NEW.currency_id")
                .contains("currency UUID must match the account currency UUID")
                .contains("balance-adjustment account and currency must be active")
                .contains("FOR SHARE OF account, currency");
        assertThat(v405)
                .contains("BEFORE UPDATE OF id, is_base_currency, status, is_deleted OR DELETE")
                .contains("functional currency UUID primary key is immutable");
    }

    @Test
    void legacyCurrencyReloadPreservesTheFunctionalCurrencyUuid() throws Exception {
        String source = Files.readString(Path.of(
                "legacy_migration/migrate_currency.sql"));

        assertThat(source)
                .doesNotContain("DELETE FROM currencies")
                .contains("ON CONFLICT (legacy_id) DO UPDATE")
                .contains("WHEN currencies.is_base_currency THEN currencies.code")
                .contains("currency import requires exactly one active legacy_id=1")
                .contains("WHERE is_base_currency AND legacy_id = 1")
                .contains("currency import changed or lost the V403 functional-currency UUID authority");
    }

    @Test
    void moneyAndDefaultCurrencyPathsUseTheUuidBoundAuthority() throws Exception {
        String payment = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/finance/payment/"
                        + "FinancePaymentService.java"));
        String salesOrder = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/sales/order/"
                        + "SalesOrderService.java"));
        String subcontractLoss = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/finance/payables/"
                        + "SubcontractLossClaimService.java"));
        String currencyService = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/master/currency/"
                        + "CurrencyService.java"));

        assertThat(payment)
                .contains("currency.is_base_currency")
                .doesNotContain("equalsIgnoreCase(currencyCode)")
                .doesNotContain("equals(currencyName");
        assertThat(salesOrder)
                .contains("AND is_base_currency")
                .doesNotContain("standardCny")
                .doesNotContain("namedRenminbi");
        assertThat(subcontractLoss)
                .contains("AND is_base_currency")
                .doesNotContain("UPPER(BTRIM(code)) IN ('CNY','RMB')");
        assertThat(currencyService)
                .contains("本位币 UUID 不能停用")
                .contains("本位币 UUID 不能删除");
    }
}
