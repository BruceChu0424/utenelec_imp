package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class AccountPaymentStyleUuidContractTest {

    @Test
    void v267AddsValidatedUuidTruthAndPostingResolverPrefersIt() throws IOException {
        String sql = compact(read("src/main/resources/db/migration/"
                + "V267__account_payment_style_uuid.sql"));

        assertThat(sql)
                .contains("alter table accounts add column style_id uuid")
                .contains("foreign key (style_id) references payment_styles(id)")
                .contains("alter table accounts validate constraint fk_accounts_style")
                .contains("alter table payment_styles validate constraint fk_payment_styles_linked_account")
                .contains("historical and disabled rows still need a uuid identity")
                .contains("accounts style uuid backfill has %s orphan or non-account mappings")
                .contains("active accounts have %s disabled, deleted, or non-leaf style mappings")
                .contains("payment style linked-account uuid backfill has %s invalid mappings")
                .contains("select account.style_id")
                .contains("account.style_id is null and style.legacy_id = account.style_legacy_id")
                .contains("create trigger trg_psref_accounts_style_uuid")
                .contains("create trigger trg_psref_accounts_active_uuid")
                .contains("create trigger trg_psref_accounts_active_legacy")
                .contains("create trigger trg_psref_style_active_accounts")
                .contains("收付款类别仍被使用中的账户引用，不能停用或删除")
                .contains("before insert or update of style_id on accounts")
                .doesNotContain("drop trigger if exists trg_psref_accounts_style");

        String legacyFinance = compact(read("legacy_migration/migrate_finance.sql"));
        assertThat(legacyFinance)
                .contains("update payment_styles set linked_account_id = null")
                .contains("delete from accounts")
                .contains("chr(20351) || chr(29992)")
                .contains("left join payment_styles s on s.id = a.style_id")
                .contains("s.legacy_id is distinct from a.style_legacy_id")
                .doesNotContain("ar_ap_ledger, accounts");
        assertThat(legacyFinance.indexOf("set session_replication_role = default"))
                .isLessThan(legacyFinance.indexOf("delete from accounts"));
    }

    @Test
    void normalServicesResolveLegacyFallbackIntoUuidInsteadOfPersistingLegacyOnly() throws IOException {
        String accounts = compact(read("src/main/java/com/uten/imp/features/master/account/AccountService.java"));
        String styles = compact(read("src/main/java/com/uten/imp/features/master/paymentstyle/PaymentStyleService.java"));

        assertThat(accounts)
                .contains("account.setstyleid((uuid) resolved[0])")
                .contains("account.setstylelegacyid(")
                .doesNotContain("a.setstylelegacyid(req.getstylelegacyid())");
        assertThat(styles)
                .contains("style.setlinkedaccountid((uuid) resolved[0])")
                .contains("style.setlinkedaccountlegacyid(")
                .doesNotContain("s.setlinkedaccountlegacyid(req.getlinkedaccountlegacyid())");
    }

    private static String read(String relative) throws IOException {
        Path direct = Path.of(relative);
        Path path = Files.exists(direct) ? direct : Path.of("server").resolve(relative);
        return Files.readString(path, StandardCharsets.UTF_8);
    }

    private static String compact(String value) {
        return value.toLowerCase(Locale.ROOT).replaceAll("\\s+", " ").trim();
    }
}
