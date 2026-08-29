package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;

class AccountBalanceReconciliationMigrationContractTest {

    @Test
    void v400CreatesImmutableAuditedBalanceFactsAndFailsClosedOnOldDrift()
            throws Exception {
        String sql = normalized();

        assertThat(sql)
                .contains("balance_current is distinct from init_balance + receipts_total - payments_total")
                .contains("add column balance_adjustments_total numeric(18,4) not null default 0")
                .contains("add column balance_floor numeric(18,4)")
                .contains("active accounts have missing, disabled, or deleted currency uuids")
                .contains("currency_id is null and legacy_id is not null")
                .contains("hashtextextended('payment_style_hierarchy',0)")
                .contains("hashtextextended('account_master_population',0)")
                .contains("where legacy_id in (1,3) or id in ( select account.currency_id")
                .contains("and account.currency_id is not null) order by id for share")
                .contains("order by id for update")
                .contains("account_type='offshore'")
                .contains("currencies.legacy_id=1 row; found %s")
                .contains("currencies.legacy_id=3 row; found %s")
                .contains("where currency_id is null and legacy_id is not null")
                .contains("ck_accounts_active_currency_uuid")
                .contains("fn_guard_active_account_currency")
                .contains("fn_guard_currency_with_active_accounts")
                .contains("active account currency authority changed during v400")
                .contains("= init_balance + receipts_total - payments_total + balance_adjustments_total")
                .contains("create table account_balance_adjustment_batches")
                .contains("create table account_balance_adjustment_items")
                .contains("unique(batch_id, account_id)")
                .contains("delta_balance = target_balance - expected_balance")
                .contains("delta_local = round(delta_balance * exchange_rate_snapshot, 4)")
                .contains("expected_item_count integer not null")
                .contains("changed_item_count integer not null")
                .contains("currency_id uuid not null references currencies(id)")
                .contains("fn_validate_account_balance_adjustment_batch_shape")
                .contains("deferrable initially deferred")
                .contains("account balance adjustment batch shape mismatch")
                .contains("fn_guard_balance_adjustment_clearing_snapshot")
                .contains("fn_guard_balance_adjustment_clearing_leaf")
                .contains("fn_guard_account_balance_adjustment_append_only")
                .contains("fn_guard_balance_adjustment_reconciliation_append_only")
                .contains("trg_guard_balance_adjustment_reconciliation_append_only")
                .contains("trg_audit_account_balance_adjustment_batches")
                .contains("trg_audit_account_balance_adjustment_items");
        int hierarchyLock = sql.indexOf("hashtextextended('payment_style_hierarchy',0)");
        int accountLock = sql.indexOf("hashtextextended('account_master_population',0)");
        int currencyRows = sql.indexOf("from currencies", accountLock);
        int accountRows = sql.indexOf("from accounts", currencyRows);
        assertThat(hierarchyLock).isGreaterThanOrEqualTo(0);
        assertThat(accountLock).isGreaterThan(hierarchyLock);
        assertThat(currencyRows).isGreaterThan(accountLock);
        assertThat(accountRows).isGreaterThan(currencyRows);
    }

    @Test
    void v400RegistersTzNumberFlowTypeClearingRoleAndFineGrainedPermissions()
            throws Exception {
        String sql = normalized();

        assertThat(sql)
                .contains("'fin_account_balance_adjustment', 'document', 'tz'")
                .contains("trg_business_document_account_balance_adjustment_batches")
                .contains("'balance_adjustment'" )
                .contains("'account_balance_clearing'")
                .contains("'账户余额调整清算', 'equity'")
                .contains("system posting role cannot be renamed, moved, disabled, deleted, or recategorized")
                .contains("'account:balance:view'")
                .contains("'account:flow:view'")
                .contains("'account:warning:manage'")
                .contains("'account:balance:adjust'")
                .contains("surface.surface_key = 'basic.account'")
                .contains("permission.code in ( 'account:balance:view', 'account:flow:view') where department.code = 'gm'")
                .contains("fn_guard_department_account_balance_adjustment")
                .contains("账户余额校准权限仅允许全局权限页逐人授权");
    }

    @Test
    void legacyFinanceImportUsesTheSameReviewedCurrencySplit() throws Exception {
        String sql = java.nio.file.Files.readString(java.nio.file.Path.of(
                        "legacy_migration/migrate_finance.sql"), StandardCharsets.UTF_8)
                .replaceAll("--[^\r\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();

        assertThat(sql)
                .contains("legacy rmb account import requires exactly one active currencies.legacy_id=1 row")
                .contains("legacy offshore account import requires exactly one active currencies.legacy_id=3 row")
                .contains("legacy_id, code, name, bank_account_no, account_type, currency_id")
                .contains("when s.name like '%' || chr(39321) || '%' then")
                .contains("where currency.legacy_id=3")
                .contains("where currency.legacy_id=1");
        String conservation = "balance_current <> init_balance + receipts_total - payments_total "
                + "+ balance_adjustments_total";
        assertThat(sql).contains(conservation);
        assertThat(sql.indexOf(conservation)).isNotEqualTo(sql.lastIndexOf(conservation));
        int hierarchyLock = sql.indexOf("hashtextextended('payment_style_hierarchy',0)");
        int accountLock = sql.indexOf("hashtextextended('account_master_population',0)");
        int destructiveWrite = sql.indexOf("update payment_styles");
        assertThat(hierarchyLock).isGreaterThanOrEqualTo(0);
        assertThat(accountLock).isGreaterThan(hierarchyLock);
        assertThat(destructiveWrite).isGreaterThan(accountLock);
    }

    private static String normalized() throws Exception {
        try (var stream = AccountBalanceReconciliationMigrationContractTest.class
                .getResourceAsStream(
                        "/db/migration/V400__account_balance_reconciliation.sql")) {
            if (stream == null) throw new IllegalStateException("V400 migration missing");
            return new String(stream.readAllBytes(), StandardCharsets.UTF_8)
                    .replaceAll("--[^\\r\\n]*", " ")
                    .replaceAll("\\s+", " ")
                    .trim()
                    .toLowerCase();
        }
    }
}
