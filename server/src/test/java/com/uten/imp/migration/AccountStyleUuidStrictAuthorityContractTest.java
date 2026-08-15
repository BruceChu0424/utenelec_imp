package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class AccountStyleUuidStrictAuthorityContractTest {

    @Test
    void v277ConsumesHistoricalPathDefaultsOnceAndInstallsUuidOnlyGuards()
            throws IOException {
        String sql = compact(read("src/main/resources/db/migration/"
                + "V277__account_style_uuid_strict_authority.sql"));

        assertThat(sql)
                .contains("drop trigger if exists trg_psref_accounts_active_legacy on accounts")
                .contains("drop trigger if exists trg_psref_accounts_style on accounts")
                .contains("pg_advisory_xact_lock( hashtextextended('payment_style_hierarchy', 0))")
                .contains("insert into payment_styles")
                .contains("where existing.path = '/' || required.code || '/'")
                .contains("case when account.account_type = 'cash' then '/101/' else '/102/' end")
                .contains("match_count <> 1")
                .contains("style.category = 'account'")
                .contains("not exists ( select 1 from payment_styles child")
                .contains("set style_id = target.id, style_legacy_id = target.legacy_id")
                .contains("ck_accounts_active_style_uuid")
                .contains("ck_accounts_style_shadow_requires_uuid")
                .contains("ck_payment_styles_linked_account_shadow_requires_uuid")
                .contains("create trigger trg_account_style_uuid_authority")
                .contains("create trigger trg_payment_style_account_uuid_authority")
                .contains("create or replace function fn_guard_active_account_style_status()")
                .contains("account.status = '使用'")
                .contains("does not reference an active account")
                .contains("uuid conflicts with legacy shadow");

        String reverseGuard = isolateFunction(
                sql, "fn_guard_active_account_style_status", "fn_enforce_payment_style_account_uuid_authority");
        assertThat(reverseGuard)
                .contains("account.style_id = new.id")
                .doesNotContain("style_legacy_id");

        String linkedAccountGuard = isolateFunction(
                sql, "fn_enforce_payment_style_account_uuid_authority", "account_style_id");
        assertThat(linkedAccountGuard)
                .contains("account.status = '使用'")
                .contains("coalesce(account.is_deleted, false) = false")
                .doesNotContain("where account.legacy_id");

        String resolver = sql.substring(sql.lastIndexOf(
                "create or replace function account_style_id"));
        assertThat(resolver)
                .contains("select account.style_id from accounts account where account.id = p_account_id")
                .doesNotContain("coalesce(")
                .doesNotContain("style_legacy_id")
                .doesNotContain("/101/")
                .doesNotContain("/102/");
    }

    @Test
    void normalJavaAndFlutterWritersDoNotResolveLegacyRelations()
            throws IOException {
        String accounts = compact(read(
                "src/main/java/com/uten/imp/features/master/account/AccountService.java"));
        String styles = compact(read(
                "src/main/java/com/uten/imp/features/master/paymentstyle/PaymentStyleService.java"));
        String styleRepository = compact(read(
                "src/main/java/com/uten/imp/features/master/paymentstyle/PaymentStyleRepository.java"));
        String accountPage = compact(read(
                "../lib/features/basic_data/pages/account_page.dart"));
        String styleModel = compact(read(
                "../lib/features/basic_data/models/payment_style_node.dart"));

        assertThat(accounts)
                .contains("stylelegacyid 不能用于建立关联")
                .contains("and id=:styleid")
                .contains("使用中的账户必须选择会计科目 uuid")
                .doesNotContain("legacy_id=:reference");
        assertThat(styles)
                .contains("linkedaccountlegacyid 不能用于建立关联")
                .contains("and id=:accountid")
                .doesNotContain("legacy_id=:reference");
        assertThat(styleRepository)
                .contains("account.style_id in (select id from style_subtree)")
                .doesNotContain("account.style_legacy_id");
        assertThat(accountPage)
                .contains("key: 'styleid'")
                .contains("required: true")
                .contains("activeaccountstyleleaves(roots)")
                .contains("class accountstyleloadnotice")
                .contains("'styleid': styleavailable ? d.styleid! : ''");

        String saveInput = styleModel.substring(
                styleModel.indexOf("class paymentstylesaveinput"));
        assertThat(saveInput)
                .doesNotContain("'linkedaccountlegacyid'")
                .contains("'linkedaccountid': linkedaccountid");
    }

    private static String read(String relative) throws IOException {
        Path direct = Path.of(relative).normalize();
        Path path = Files.exists(direct)
                ? direct : Path.of("server").resolve(relative).normalize();
        return Files.readString(path, StandardCharsets.UTF_8);
    }

    private static String compact(String value) {
        return value.toLowerCase(Locale.ROOT).replaceAll("\\s+", " ").trim();
    }

    private static String isolateFunction(String sql, String name, String nextName) {
        int start = sql.indexOf("create or replace function " + name);
        int end = sql.indexOf("create or replace function " + nextName, start + 1);
        return sql.substring(start, end);
    }
}
