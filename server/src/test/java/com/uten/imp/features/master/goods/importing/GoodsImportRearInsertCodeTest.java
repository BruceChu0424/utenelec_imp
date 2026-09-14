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

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 后模镶件编号（V457）的导出 / 导入闭环。
 *
 * <p>导出一直在写「后模镶件编号」这一列，而导入的表头别名表里没有它；未识别的
 * 表头会被静默跳过，于是「导出 → 在表里改 → 再导入」会把用户填的镶件编号悄悄
 * 吃掉，界面上没有任何提示。这批用例锁住三件事：表头认得出、值能落到解析行、
 * 超长按行报错而不是截断。</p>
 */
class GoodsImportRearInsertCodeTest {

    private static final String REAR_INSERT_HEADER = "后模镶件编号";

    @Test
    void parse_readsTheExportedRearInsertCodeColumn() throws Exception {
        // 修复前：表头未登记 → 列被跳过 → 该字段为 null。
        assertEquals("45A", parsedRearInsertCode(workbook("45A")));
    }

    @Test
    void parse_acceptsTheShorthandHeadersUsersActuallyType() throws Exception {
        assertEquals("1M仁", parsedRearInsertCode(workbook("后模镶件", "1M仁")));
        assertEquals("V7-012", parsedRearInsertCode(workbook("镶件编号", "V7-012")));
    }

    @Test
    void parse_keepsAnEmptyCellEmptyInsteadOfInventingAValue() throws Exception {
        assertEquals("", parsedRearInsertCode(workbook("")));
    }

    @Test
    void detect_acceptsExactlyOneHundredCharacters() throws Exception {
        GoodsImportReport report = service(mock(GoodsRepository.class))
                .detect(workbook("平".repeat(100)));

        assertTrue(report.errors().isEmpty(), () -> "unexpected: " + report.errors());
    }

    @Test
    void detect_rejectsAnOverLongRearInsertCodeInsteadOfTruncatingIt() throws Exception {
        // 镶件编号是标识符：截断会得到一个「看着正常、实际指错镶件」的编号，
        // 比让用户回表格改一格危险得多，所以按行报错。
        GoodsImportReport report = service(mock(GoodsRepository.class))
                .detect(workbook("平".repeat(101)));

        assertEquals(1, report.errors().size());
        assertEquals(REAR_INSERT_HEADER, report.errors().get(0).column());
        assertTrue(report.errors().get(0).message().contains("100"),
                () -> "message should name the limit: " + report.errors().get(0).message());
        assertEquals(0, report.readyToImport());
    }

    @Test
    void commitPathWritesTheFieldOntoTheSaveRequest() throws Exception {
        // 提交路径要落库，纯单测够不到；这里锁住接线本身，防止解析出来
        // 却忘了写进 GoodsSaveRequest（那等于什么都没修）。
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/master/goods/importing/GoodsImportService.java"));

        assertTrue(source.contains("req.setRearInsertCode(emptyToNull(r.rearInsertCode))"));
    }

    private static String parsedRearInsertCode(byte[] xlsx) throws Exception {
        GoodsImportService service = service(mock(GoodsRepository.class));
        Method parse = GoodsImportService.class.getDeclaredMethod("parse", byte[].class);
        parse.setAccessible(true);
        Object parsed = parse.invoke(service, (Object) xlsx);
        Field rowsField = parsed.getClass().getDeclaredField("rows");
        rowsField.setAccessible(true);
        List<?> rows = (List<?>) rowsField.get(parsed);
        assertEquals(1, rows.size());
        Object row = rows.get(0);
        Field field = row.getClass().getDeclaredField("rearInsertCode");
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
                null, colors, null, units, null, currentUser);
    }

    private static byte[] workbook(String rearInsertCode) throws Exception {
        return workbook(REAR_INSERT_HEADER, rearInsertCode);
    }

    private static byte[] workbook(String header, String rearInsertCode) throws Exception {
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
            row.createCell(3).setCellValue(rearInsertCode);
            workbook.write(output);
            return output.toByteArray();
        }
    }
}
