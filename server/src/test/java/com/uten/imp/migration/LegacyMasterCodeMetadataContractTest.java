package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class LegacyMasterCodeMetadataContractTest {

    private static final Pattern MASTER_INSERT = Pattern.compile(
            "(?is)INSERT\\s+INTO\\s+(goods|moulds|clients|suppliers)\\s*\\(([^)]+)\\)");

    @Test
    void everyOfflineMasterInsertReservesAndWritesV258SequenceMetadata() throws IOException {
        for (String file : List.of(
                "migrate_goods_data.sql", "migrate_mould_data.sql",
                "migrate_client_data.sql", "migrate_supplier_data.sql",
                "migrate_finance.sql", "migrate_production.sql", "migrate_sales.sql",
                "migrate_subcontract.sql", "migrate_stock_docs.sql")) {
            String sql = sourceFile("legacy_migration/" + file);
            Matcher matcher = MASTER_INSERT.matcher(sql);
            int inserts = 0;
            while (matcher.find()) {
                inserts++;
                String columns = matcher.group(2).replaceAll("\\s+", " ").toLowerCase();
                assertTrue(columns.contains("code_managed"), file + " 缺 code_managed: " + matcher.group(1));
                assertTrue(columns.contains("code_sequence"), file + " 缺 code_sequence: " + matcher.group(1));
            }
            assertTrue(inserts > 0, file + " 未找到主档 INSERT");
            assertEquals(inserts, count(sql, "INSERT INTO category_master_code_sequences"),
                    file + " 每条主档 INSERT 都必须预留独立序号段");
        }
    }

    @Test
    void offlineCategoryLoadsKeepLegacyCodeOnlyAsTraceAndUseInternalCodes() throws IOException {
        assertCategoryScript("migrate_goods.sql", "material_categories", "FL");
        assertCategoryScript("migrate_mould.sql", "mould_categories", "MF");
        assertCategoryScript("migrate_client.sql", "client_categories", "KF");
        assertCategoryScript("migrate_supplier.sql", "supplier_categories", "GF");
    }

    private static void assertCategoryScript(String file, String table, String prefix) throws IOException {
        String sql = sourceFile("legacy_migration/" + file);
        Pattern insert = Pattern.compile(
                "(?is)INSERT\\s+INTO\\s+" + table + "\\s*\\(([^)]+)\\)");
        Matcher matcher = insert.matcher(sql);
        int inserts = 0;
        while (matcher.find()) {
            inserts++;
            String columns = matcher.group(1).replaceAll("\\s+", " ").toLowerCase();
            assertTrue(columns.contains("remark"), file + " 旧编码必须写备注");
            assertTrue(columns.contains("legacy_code_snapshot"), file + " 旧编码必须冻结快照");
        }
        assertTrue(inserts > 0, file + " 未找到分类 INSERT");
        assertTrue(sql.contains("pg_temp.next_category_code('" + prefix + "')"));
        assertTrue(sql.contains("INSERT INTO master_code_sequences"));
    }

    private static int count(String source, String token) {
        int result = 0;
        for (int offset = 0; (offset = source.indexOf(token, offset)) >= 0; offset += token.length()) {
            result++;
        }
        return result;
    }

    private static String sourceFile(String serverRelativePath) throws IOException {
        Path direct = Path.of(serverRelativePath);
        Path path = Files.exists(direct) ? direct : Path.of("server").resolve(serverRelativePath);
        return Files.readString(path, StandardCharsets.UTF_8);
    }
}
