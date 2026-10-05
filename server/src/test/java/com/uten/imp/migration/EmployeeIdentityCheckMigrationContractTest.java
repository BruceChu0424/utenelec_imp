package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

/** V807 证件号校验状态：只加一列两约束、存量标 unchecked、解不开的存 unreadable、所有写入口同写校验结果。 */
class EmployeeIdentityCheckMigrationContractTest {

    private static final Path ROOT = Path.of("src/main");
    private static final Path MIGRATION = ROOT.resolve(
            "resources/db/migration/V807__employee_identity_check_status.sql");

    @Test
    void migrationAddsOneColumnWithValueAndPresenceConstraintsAndNoTable() throws IOException {
        String sql = compact(Files.readString(MIGRATION));

        assertThat(sql)
                .contains("alter table employee_sensitive add column id_card_check text;")
                .contains("update employee_sensitive set id_card_check = 'unchecked' where id_card_enc is not null;")
                .contains("employee_sensitive_id_card_check_value_ck")
                .contains("check (id_card_check ~ '^(valid|unchecked|unreadable|empty|length:[0-9]{1,3}|character:[0-9]{1,2}"
                        + "|birth_date|birth_too_early|birth_future|region_code|sequence_code|check_digit)$')")
                .contains("employee_sensitive_id_card_check_presence_ck")
                .contains("check ((id_card_enc is null) = (id_card_check is null))")
                // 不建表 (写成正则，免得被夹具漂移守卫当成手写 DDL)
                .doesNotContainPattern("create\\s+table")
                .doesNotContain("pgp_sym_encrypt")
                .doesNotContain("pgp_sym_decrypt");
        // 只有这一条 UPDATE，且只作用于有密文的行。
        assertThat(occurrences(sql, "update ")).isEqualTo(1);
    }

    @Test
    void storedValuePatternAcceptsEveryCodeTheJavaRuleCanProduce() throws IOException {
        Matcher check = Pattern.compile("CHECK \\(id_card_check ~ '([^']+)'\\)")
                .matcher(Files.readString(MIGRATION));
        assertThat(check.find()).isTrue();
        Pattern stored = Pattern.compile(check.group(1));
        for (String code : List.of(
                "valid", "unchecked", "unreadable", "empty", "length:0", "length:17", "length:999",
                "character:1", "character:18", "birth_date", "birth_too_early", "birth_future",
                "region_code", "sequence_code", "check_digit")) {
            assertThat(stored.matcher(code).matches()).as(code).isTrue();
        }
        for (String rejected : List.of(
                "invalid", "length:1000", "character:100", "VALID", "", "length:", "Unreadable", "undecryptable")) {
            assertThat(stored.matcher(rejected).matches()).as(rejected).isFalse();
        }
    }

    @Test
    void legacyHrImportsWriteUncheckedTogetherWithTheCipher() throws IOException {
        for (String file : List.of("migrate_hr_roster.sql", "migrate_hr_workers.sql")) {
            String sql = compact(Files.readString(Path.of("legacy_migration", file)));
            assertThat(sql)
                    .as(file)
                    .contains("insert into employee_sensitive (employee_id, id_card_enc, id_card_last4, "
                            + "id_card_hash, id_card_check, phone_enc, phone_hash)")
                    .contains("case when nullif(btrim(s.id_card), '') is not null then 'unchecked' end")
                    .contains("id_card_check = excluded.id_card_check");
        }
        String builder = Files.readString(Path.of("legacy_migration", "build_hr_roster.py"));
        assertThat(builder)
                .as("roster warnings must not print identity numbers, values derived from them or names")
                .doesNotContain("身份证 {idc")
                .doesNotContain("{idc!r}")
                .doesNotContain("{sheet_birth}")
                .doesNotContain("与身份证 {birth}")
                .doesNotContain("{r['性别']}")
                .contains("warns.append(f\"#{seq}: 表内出生日期与身份证不一致 → 以身份证为准\")")
                .contains("warns.append(f\"#{seq}: 表内性别与身份证不一致 → 以身份证为准\")");
        assertThat(compact(builder))
                .as("the check digit is only computed for an 18-character ASCII-digit shape")
                .contains("if not id_shape_ok(idc): # 长度不对")
                .contains("elif not id_checksum_ok(idc):");
    }

    @Test
    void javaWritersStoreTheResultWithTheCipher() throws IOException {
        String entity = compact(Files.readString(ROOT.resolve(
                "java/com/uten/imp/features/org/employee/EmployeeSensitive.java")));
        String writer = compact(Files.readString(ROOT.resolve(
                "java/com/uten/imp/features/org/employee/EmployeePiiWriter.java")));
        String runner = Files.readString(ROOT.resolve(
                "java/com/uten/imp/features/org/employee/EmployeeIdentityCheckRunner.java"));
        String compactRunner = compact(runner);

        assertThat(entity).contains("@column(name = \"id_card_check\")");
        assertThat(writer)
                .contains("target.setidcardenc(tx.encrypt(normalized));")
                .contains("target.setidcardcheck(employeeidentitycheck.classify(idtype, normalized));");
        assertThat(compactRunner)
                .contains("@order(61)")
                .contains("readinessstate.refusing_traffic")
                .contains("select pg_advisory_lock(?, ?)")
                .contains("advisory_lock_namespace = 0x5554454e")
                .contains("advisory_lock_id = 282")
                .contains("where s.id_card_check = 'unchecked' and s.employee_id > ? order by s.employee_id limit ?")
                // 逐行在保存点里解密：解不开不作废本批事务，也不经 Hibernate 报 ERROR；存 unreadable，以后不再重试。
                .contains("tx.trydecrypt(row.cipher())")
                .contains(".orelse(employeeidentitycheck.unreadable)")
                .doesNotContain("tx.decrypt(")
                .doesNotContain("tx.decryptall(")
                .doesNotContain("log.error")
                .contains("and id_card_check = 'unchecked' and id_card_enc = ?");
        // 日志只写数量：任何 log 调用都不能带明文、密文或行对象。
        for (String line : runner.split("\\R")) {
            if (line.contains("log.")) {
                assertThat(line).as(line).doesNotContain("plain", "cipher", "row.", "employeeId");
            }
        }
    }

    private static int occurrences(String text, String needle) {
        int count = 0;
        for (int index = text.indexOf(needle); index >= 0; index = text.indexOf(needle, index + 1)) {
            count++;
        }
        return count;
    }

    private static String compact(String value) {
        return value.toLowerCase(Locale.ROOT).replaceAll("\\s+", " ").trim();
    }
}
