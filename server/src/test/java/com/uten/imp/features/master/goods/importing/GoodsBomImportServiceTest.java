package com.uten.imp.features.master.goods.importing;

import com.uten.imp.features.master.goods.Goods;
import com.uten.imp.features.master.goods.GoodsBomPasteService;
import com.uten.imp.features.master.goods.GoodsRepository;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.lang.reflect.Method;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 组装信息导入的文件侧校验（2026-09-25「导入的格式和导出的一样」）。
 *
 * <p>锁住六件容易回归的事：序号级联段能建出层级、按物料编号匹配到货品、
 * 编号查不到/序号非法/父序号缺失/序号重复按行报错、目标货品自身出现在文件里
 * 拒绝（防自环）、名称不一致只是提醒不拦提交。写入路径（按层 paste）由
 * GoodsBomPasteService 的既有行为保证，这里只测文件侧。</p>
 */
class GoodsBomImportServiceTest {

    private final UUID targetId = UUID.randomUUID();
    private final UUID shellId = UUID.randomUUID();
    private final UUID screwId = UUID.randomUUID();
    private final UUID washerId = UUID.randomUUID();

    private GoodsBomImportService service(GoodsRepository repo) {
        return new GoodsBomImportService(repo, mock(GoodsBomPasteService.class));
    }

    private GoodsRepository repoWithAllCodes() {
        GoodsRepository repo = mock(GoodsRepository.class);
        when(repo.findById(targetId)).thenReturn(Optional.of(goods(targetId, "P-1")));
        when(repo.findByCodeAndDeletedFalse("K01"))
                .thenReturn(Optional.of(goods(shellId, "K01")));
        when(repo.findByCodeAndDeletedFalse("S01"))
                .thenReturn(Optional.of(goods(screwId, "S01")));
        when(repo.findByCodeAndDeletedFalse("D01"))
                .thenReturn(Optional.of(goods(washerId, "D01")));
        when(repo.findByCodeAndDeletedFalse("P-1"))
                .thenReturn(Optional.of(goods(targetId, "P-1")));
        return repo;
    }

    private static Goods goods(UUID id, String code) {
        Goods goods = new Goods();
        goods.setId(id);
        goods.setCode(code);
        goods.setName("货品" + code);
        return goods;
    }

    private static Object parsedRows(GoodsBomImportService service, UUID goodsId, byte[] xlsx)
            throws ReflectiveOperationException {
        Method method = GoodsBomImportService.class.getDeclaredMethod(
                "parseAndValidate", UUID.class, byte[].class);
        method.setAccessible(true);
        return method.invoke(service, goodsId, xlsx);
    }

    private static java.util.List<?> rowsOf(Object parsed) throws ReflectiveOperationException {
        java.lang.reflect.Field field = parsed.getClass().getDeclaredField("rows");
        field.setAccessible(true);
        return (java.util.List<?>) field.get(parsed);
    }

    private static java.util.List<?> errorsOf(Object parsed) throws ReflectiveOperationException {
        java.lang.reflect.Field field = parsed.getClass().getDeclaredField("errors");
        field.setAccessible(true);
        return (java.util.List<?>) field.get(parsed);
    }

    private static java.util.List<?> warningsOf(Object parsed) throws ReflectiveOperationException {
        java.lang.reflect.Field field = parsed.getClass().getDeclaredField("warnings");
        field.setAccessible(true);
        return (java.util.List<?>) field.get(parsed);
    }

    private static String errorText(Object parsed) {
        try {
            StringBuilder text = new StringBuilder();
            for (Object error : errorsOf(parsed)) {
                text.append(error).append('\n');
            }
            return text.toString();
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException(e);
        }
    }

    @Test
    void twoLevelTreeParsesWithLevelCounts() throws Exception {
        BomImportReport report = service(repoWithAllCodes())
                .detect(targetId, workbook(new String[][]{
                        {"1", "K01", "2"},
                        {"2", "S01", "4"},
                        {"2.1", "D01", "1"},
                }));
        assertTrue(report.errors().isEmpty(), () -> "unexpected: " + report.errors());
        assertEquals(3, report.totalRows());
        // 两层：顶层 2 行、第二层 1 行。
        assertEquals(java.util.List.of(2, 1), report.levelCounts());
    }

    @Test
    void unknownCodeIsARowError() throws Exception {
        BomImportReport report = service(repoWithAllCodes())
                .detect(targetId, workbook(new String[][]{
                        {"1", "NOPE", "2"},
                }));
        assertEquals(1, report.errors().size());
        assertEquals("物料编号", report.errors().get(0).column());
        assertTrue(report.errors().get(0).message().contains("NOPE"));
    }

    @Test
    void malformedSeqAndMissingParentAreRowErrors() throws Exception {
        BomImportReport report = service(repoWithAllCodes())
                .detect(targetId, workbook(new String[][]{
                        {"1-1", "K01", "2"},
                        {"3.1", "D01", "1"},
                }));
        assertTrue(report.errors().stream().anyMatch(e ->
                e.column().equals("序号") && e.message().contains("级联序号")));
        assertTrue(report.errors().stream().anyMatch(e ->
                e.column().equals("序号") && e.message().contains("不在文件里")));
    }

    @Test
    void duplicateSeqIsARowError() throws Exception {
        BomImportReport report = service(repoWithAllCodes())
                .detect(targetId, workbook(new String[][]{
                        {"1", "K01", "2"},
                        {"1", "S01", "4"},
                }));
        assertTrue(report.errors().stream().anyMatch(e ->
                e.column().equals("序号") && e.message().contains("重复")));
    }

    @Test
    void targetItselfInTheFileIsRejected() throws Exception {
        BomImportReport report = service(repoWithAllCodes())
                .detect(targetId, workbook(new String[][]{
                        {"1", "P-1", "2"},
                }));
        assertTrue(report.hasErrors());
        assertTrue(report.errors().get(0).message().contains("不能把货品自己"));
    }

    @Test
    void nameMismatchIsOnlyAWarning() throws Exception {
        Object parsed = parsedRows(service(repoWithAllCodes()), targetId,
                workbook(new String[][]{{"1", "K01", "2", "名字对不上"}}));
        assertTrue(((java.util.List<?>) errorsOf(parsed)).isEmpty(),
                () -> "unexpected: " + errorText(parsed));
        assertEquals(1, ((java.util.List<?>) warningsOf(parsed)).size());
    }

    /** 最小工作表：表头 + 数据行；列 = 序号/物料编号/数量/[备注]。 */
    private static byte[] workbook(String[][] dataRows) throws Exception {
        try (XSSFWorkbook workbook = new XSSFWorkbook();
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            var sheet = workbook.createSheet("配件清单");
            var header = sheet.createRow(0);
            header.createCell(0).setCellValue("序号");
            header.createCell(1).setCellValue("物料编号");
            header.createCell(2).setCellValue("数量");
            header.createCell(3).setCellValue("物料名称");
            for (int r = 0; r < dataRows.length; r++) {
                var row = sheet.createRow(r + 1);
                for (int c = 0; c < dataRows[r].length; c++) {
                    row.createCell(c).setCellValue(dataRows[r][c]);
                }
            }
            workbook.write(output);
            return output.toByteArray();
        }
    }
}
