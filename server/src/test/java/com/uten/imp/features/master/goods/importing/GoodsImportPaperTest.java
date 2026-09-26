package com.uten.imp.features.master.goods.importing;

import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.GoodsRepository;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 导入格式与导出格式对齐（2026-09-25 用户口径「导的格式和导出的一样」）。
 *
 * <p>导出一直写「备注」列（goods.paper），GoodsSaveRequest 本就开放编辑，但导入
 * 表头别名表把它登记为 ignored ——「导出 → 在表里改 → 再导入」会把备注悄悄吃掉。
 * 同一批把「模具编号 / 归属车间」从「未识别」补登记为 ignored（导出有、DTO 未开放
 * 编辑，按 UUID-only 契约按名反查不落值），与 客户型号 / 所属仓库 同口径。</p>
 */
class GoodsImportPaperTest {

    @Test
    void parse_readsTheExportedPaperColumn() throws Exception {
        // 修复前：「备注」登记为 ignored → 列被跳过 → 该字段为 null。
        assertEquals("易碎品", parsedPaper(workbook("备注", "易碎品")));
    }

    @Test
    void parse_keepsAnEmptyPaperCellEmpty() throws Exception {
        assertEquals("", parsedPaper(workbook("备注", "")));
    }

    @Test
    void commitPathWritesTheFieldOntoTheSaveRequest() throws Exception {
        // 提交路径要落库，纯单测够不到；这里锁住接线本身，防止解析出来
        // 却忘了写进 GoodsSaveRequest（那等于什么都没修）。
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/master/goods/importing/GoodsImportService.java"));
        assertTrue(source.contains("req.setPaper(emptyToNull(r.paper))"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void exportOnlyHeadersAreRecognizedAsIgnored() throws Exception {
        // 模具编号 / 归属车间 / 客户型号 / 所属仓库：导出有但导入不落值——
        // 必须显式登记为 ignored（明账），未登记会被当成待补的漏项。
        Map<String, String> aliases = headerAliases();
        assertEquals("paper", aliases.get(normKey("备注")));
        assertEquals("ignored", aliases.get(normKey("模具编号")));
        assertEquals("ignored", aliases.get(normKey("模具")));
        assertEquals("ignored", aliases.get(normKey("归属车间")));
        assertEquals("ignored", aliases.get(normKey("车间")));
        assertEquals("ignored", aliases.get(normKey("客户型号")));
        assertEquals("ignored", aliases.get(normKey("所属仓库")));
    }

    @SuppressWarnings("unchecked")
    private static Map<String, String> headerAliases() throws Exception {
        Field field = GoodsImportService.class.getDeclaredField("HEADER_ALIASES");
        field.setAccessible(true);
        return (Map<String, String>) field.get(null);
    }

    private static String normKey(String raw) throws Exception {
        Method method = GoodsImportService.class.getDeclaredMethod("normKey", String.class);
        method.setAccessible(true);
        return (String) method.invoke(null, raw);
    }

    private static String parsedPaper(byte[] xlsx) throws Exception {
        GoodsImportService service = service(mock(GoodsRepository.class));
        Method parse = GoodsImportService.class.getDeclaredMethod("parse", byte[].class);
        parse.setAccessible(true);
        Object parsed = parse.invoke(service, (Object) xlsx);
        Field rowsField = parsed.getClass().getDeclaredField("rows");
        rowsField.setAccessible(true);
        List<?> rows = (List<?>) rowsField.get(parsed);
        assertEquals(1, rows.size());
        Object row = rows.get(0);
        Field field = row.getClass().getDeclaredField("paper");
        field.setAccessible(true);
        return (String) field.get(row);
    }

    private static GoodsImportService service(GoodsRepository goods) {
        MaterialCategoryRepository categories = mock(MaterialCategoryRepository.class);
        when(categories.findByDeletedFalseOrderBySortOrderAscNameAsc()).thenReturn(List.of());
        ColorRepository colors = mock(ColorRepository.class);
        when(colors.findAll()).thenReturn(List.of());
        UnitRepository units = mock(UnitRepository.class);
        when(units.findAll()).thenReturn(List.of());
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(java.util.UUID.randomUUID());
        return new GoodsImportService(
                null, goods, null, categories,
                null, colors, null, units, null, currentUser, null);
    }

    private static byte[] workbook(String header, String value) throws Exception {
        try (XSSFWorkbook workbook = new XSSFWorkbook();
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            var sheet = workbook.createSheet("货品");
            var headerRow = sheet.createRow(0);
            headerRow.createCell(0).setCellValue("编号");
            headerRow.createCell(1).setCellValue("名称");
            headerRow.createCell(2).setCellValue("类别");
            headerRow.createCell(3).setCellValue(header);
            var row = sheet.createRow(1);
            row.createCell(0).setCellValue("V6000001");
            row.createCell(1).setCellValue("导入货品");
            row.createCell(2).setCellValue("成品-V6");
            row.createCell(3).setCellValue(value);
            workbook.write(output);
            return output.toByteArray();
        }
    }
}
