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

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** 货品导入认「英文名称」列(ADR-134): 导出的列名原样导回, 常见英文表头也认, 取值去多余空白。 */
class GoodsImportNameEnTest {

    @Test
    void exportedAndCommonEnglishHeadersMapToNameEn() throws Exception {
        Map<String, String> aliases = headerAliases();
        for (String header : List.of("英文名称", "英文名", "English Name", "english name", "ENGLISH NAME", "name_en")) {
            assertThat(aliases.get(normKey(header))).as(header).isEqualTo("nameEn");
        }
    }

    @Test
    void parseReadsAndNormalizesTheEnglishNameColumn() throws Exception {
        assertThat(parsedNameEn(workbook("英文名称", "  Double  3 PIN Socket "))).isEqualTo("Double 3 PIN Socket");
        assertThat(parsedNameEn(workbook("English Name", "   "))).isNull();
    }

    @Test
    void commitPathWritesTheFieldOntoTheSaveRequest() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/master/goods/importing/GoodsImportService.java"));
        assertThat(source).contains("if (r.nameEn != null) req.setNameEn(r.nameEn);");
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

    private static String parsedNameEn(byte[] xlsx) throws Exception {
        MaterialCategoryRepository categories = mock(MaterialCategoryRepository.class);
        when(categories.findByDeletedFalseOrderBySortOrderAscNameAsc()).thenReturn(List.of());
        ColorRepository colors = mock(ColorRepository.class);
        when(colors.findAll()).thenReturn(List.of());
        UnitRepository units = mock(UnitRepository.class);
        when(units.findAll()).thenReturn(List.of());
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(java.util.UUID.randomUUID());
        GoodsImportService service = new GoodsImportService(
                null, mock(GoodsRepository.class), null, categories,
                null, colors, null, units, null, currentUser, null);
        Method parse = GoodsImportService.class.getDeclaredMethod("parse", byte[].class);
        parse.setAccessible(true);
        Object parsed = parse.invoke(service, (Object) xlsx);
        Field rowsField = parsed.getClass().getDeclaredField("rows");
        rowsField.setAccessible(true);
        List<?> rows = (List<?>) rowsField.get(parsed);
        assertThat(rows).hasSize(1);
        Field field = rows.getFirst().getClass().getDeclaredField("nameEn");
        field.setAccessible(true);
        return (String) field.get(rows.getFirst());
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
