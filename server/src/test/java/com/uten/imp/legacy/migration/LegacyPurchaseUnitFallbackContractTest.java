package com.uten.imp.legacy.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class LegacyPurchaseUnitFallbackContractTest {

    @Test
    void allPurchaseItemImportsResolveUnitsOnlyFromExactLegacyIdentity()
            throws IOException {
        Path script = Path.of(
                System.getProperty("user.dir"),
                "legacy_migration",
                "migrate_purchase.sql");
        String sql = Files.readString(script, StandardCharsets.UTF_8);

        // V624/V626/V627 重写后口径：申请/订货/退货三张 *_items 在 loader 内按
        // NULLIF(unit_legacy_id, 0) 精确解析单位（原 4 处的第 4 处是收货明细，其单位
        // 改由 V627 fn_legacy_receipt_source_projection 以同一 NULLIF 规则给出）；
        // 「单位缺失且 rate=1 时回退货品基本单位」的确定性回退分支被有意删除——
        // 未解析单位保持 NULL，由『待治理/阻塞MRP』校验计数显式暴露，导入时绝不
        // 发明单位事实。
        assertEquals(3, occurrences(sql, "NULLIF(s.unit_legacy_id, 0)"));
        assertEquals(0, occurrences(sql, "u.legacy_id = g.unit_legacy_id"));
        assertEquals(0, occurrences(sql, "COALESCE(s.unit_legacy_id, 0) = 0"));
        assertEquals(0, occurrences(sql, "COALESCE(s.unit_rate, 1)"));
        assertFalse(sql.contains(
                "(SELECT id FROM units  WHERE legacy_id = s.unit_legacy_id)"));
        assertTrue(sql.contains("待治理 采购全链明细单位无法确定"));
        assertTrue(sql.contains("阻塞MRP 未完成订货明细单位无法确定"));

        // 收货明细（第 4 处导入）的单位解析锚在 V627 权威来源投影里，规则同为
        // 「精确 legacy_id，零/空保持 NULL」。
        String projection = Files.readString(
                Path.of(System.getProperty("user.dir"),
                        "src/main/resources/db/migration",
                        "V627__legacy_receipt_consideration_provenance.sql"),
                StandardCharsets.UTF_8);
        assertTrue(projection.contains(
                "unit:=(SELECT id FROM public.units "
                        + "WHERE legacy_id=NULLIF((s->>'unit_legacy_id')::integer,0));"));
    }

    private static int occurrences(String value, String needle) {
        int count = 0;
        int from = 0;
        while ((from = value.indexOf(needle, from)) >= 0) {
            count++;
            from += needle.length();
        }
        return count;
    }
}
