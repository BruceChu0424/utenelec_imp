package com.uten.imp.features.master.goods.importing;

import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.goods.Goods;
import com.uten.imp.features.master.goods.GoodsBomPasteService;
import com.uten.imp.features.master.goods.GoodsBomService;
import com.uten.imp.features.master.goods.GoodsRepository;
import com.uten.imp.features.master.goods.dto.BomItemSaveRequest;
import com.uten.imp.features.master.goods.dto.BomPasteRequest;
import com.uten.imp.features.master.goods.dto.BomPasteResult;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.InOrder;

import java.io.ByteArrayOutputStream;
import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.when;

/**
 * 组装信息导入的文件侧校验（2026-09-25「导入的格式和导出的一样」）。
 *
 * <p>锁住六件容易回归的事：序号级联段能建出层级、按物料编号匹配到货品、
 * 编号查不到/序号非法/父序号缺失/序号重复按行报错、目标货品自身出现在文件里
 * 拒绝（防自环）、名称不一致只是提醒不拦提交。写入路径（按层 paste）由
 * GoodsBomPasteService 的既有行为保证，这里只测文件侧。</p>
 *
 * <p>ADR-129：表头认「设计使用数量」与旧表头「数量」；「真实使用数量」是只读列，认得但不读；
 * 设计使用数量留空按行报错，不再静默按 1。导出的文件原样导回，数值按存的值读(不按两位小数的显示格式)。</p>
 *
 * <p>提交先按 id 顺序一次锁住所有要写的父件，再按层粘贴(与学习引擎同一锁序)。</p>
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

    @Test
    void designUsageHeaderIsReadAndActualUsageColumnIsIgnored() throws Exception {
        // 导出文件原样导回：真实使用数量列里是什么都不读、不报错。
        BomImportReport report = service(repoWithAllCodes())
                .detect(targetId, workbook(new String[]{"序号", "物料编号", "设计使用数量", "真实使用数量"},
                        new String[][]{
                                {"1", "K01", "2", "1.85"},
                                {"2", "S01", "4", "—"},
                        }));
        assertTrue(report.errors().isEmpty(), () -> "unexpected: " + report.errors());
        assertEquals(2, report.totalRows());
    }

    @Test
    void blankOrInvalidDesignUsageIsARowErrorNamedByTheColumn() throws Exception {
        BomImportReport report = service(repoWithAllCodes())
                .detect(targetId, workbook(new String[][]{
                        {"1", "K01", ""},
                        {"2", "S01", "abc"},
                        {"3", "D01", "0"},
                }));
        assertEquals(3, report.errors().size(), () -> "unexpected: " + report.errors());
        assertTrue(report.errors().stream().allMatch(e -> e.column().equals("设计使用数量")));
        assertEquals("设计使用数量不能为空", report.errors().get(0).message());
        assertEquals("设计使用数量「abc」不是有效数字", report.errors().get(1).message());
        assertEquals("设计使用数量必须大于 0", report.errors().get(2).message());
    }

    @Test
    void missingDesignUsageColumnIsNamedInPlainWords() throws Exception {
        BomImportReport report = service(repoWithAllCodes())
                .detect(targetId, workbook(new String[]{"序号", "物料编号", "真实使用数量"},
                        new String[][]{{"1", "K01", "2"}}));
        assertEquals(1, report.errors().size());
        assertEquals("缺少必填列：设计使用数量", report.errors().get(0).message());
    }

    @Test
    void exportedWorkbookRoundTripsFullPrecisionAndLocksEveryParentBeforeWriting() throws Exception {
        GoodsRepository repo = repoWithAllCodes();
        GoodsBomPasteService paste = mock(GoodsBomPasteService.class);
        when(paste.paste(any())).thenReturn(new BomPasteResult(1, 1, 0, List.of(), List.of()));
        // 真正的导出格式：用量列是数值单元格，常规格式按存储值全精度显示。
        byte[] xlsx = savedAgain(new XlsxExportService().build(GoodsBomService.EXPORT_COLUMNS, List.of(
                exportRow("1", "K01", "按包装", "2.5", "允许", "0.03125", "0.031"),
                exportRow("2", "S01", "按每件", "1", "—", "0.004", null),
                exportRow("2.1", "D01", "按每件", "1", "—", "0.00001", null))));
        try (XSSFWorkbook book = new XSSFWorkbook(new java.io.ByteArrayInputStream(xlsx))) {
            int qtyColumn = GoodsBomService.EXPORT_COLUMNS.stream().map(c -> c.key()).toList().indexOf("qty");
            var cell = book.getSheetAt(0).getRow(2).getCell(qtyColumn);
            assertEquals("General", cell.getCellStyle().getDataFormatString());
            assertEquals("0.004", new org.apache.poi.ss.usermodel.DataFormatter().formatCellValue(cell));
        }

        new GoodsBomImportService(repo, paste).commit(targetId, xlsx, BomPasteRequest.Mode.APPEND);

        InOrder order = inOrder(repo, paste);
        @SuppressWarnings("unchecked")
        ArgumentCaptor<Collection<UUID>> locked = ArgumentCaptor.forClass(Collection.class);
        order.verify(repo).lockBomParents(locked.capture());
        order.verify(paste, times(2)).paste(any());
        assertEquals(Set.of(targetId, screwId), Set.copyOf(locked.getValue()));
        ArgumentCaptor<BomPasteRequest> requests = ArgumentCaptor.forClass(BomPasteRequest.class);
        org.mockito.Mockito.verify(paste, times(2)).paste(requests.capture());
        List<BomItemSaveRequest> top = requests.getAllValues().get(0).items();
        List<BomItemSaveRequest> child = requests.getAllValues().get(1).items();
        assertExact("0.03125", top.get(0).getQty());
        assertExact("2.5", top.get(0).getBasisOutputQty());
        assertExact("0.004", top.get(1).getQty());
        assertExact("0.00001", child.get(0).getQty());
        assertEquals(screwId, requests.getAllValues().get(1).targets().get(0).goodsId());
    }

    @Test
    void formulaCellsAreRejectedBeforeAnyQuantityIsRead() throws Exception {
        // 数量只按存的值读：公式(比如显示 #DIV/0! 的 =B9/C9)整份拒收，不会把公式文字里的数字当成数量。
        byte[] xlsx;
        try (XSSFWorkbook workbook = new XSSFWorkbook();
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            var sheet = workbook.createSheet("配件清单");
            var header = sheet.createRow(0);
            header.createCell(0).setCellValue("序号");
            header.createCell(1).setCellValue("物料编号");
            header.createCell(2).setCellValue("设计使用数量");
            var row = sheet.createRow(1);
            row.createCell(0).setCellValue("1");
            row.createCell(1).setCellValue("K01");
            row.createCell(2).setCellFormula("B9/C9");
            workbook.write(output);
            xlsx = output.toByteArray();
        }

        ApiException error = assertThrows(ApiException.class,
                () -> service(repoWithAllCodes()).detect(targetId, xlsx));

        assertEquals("商品导入不执行公式，请先将公式复制并粘贴为值", error.getMessage());
    }

    /** 导出文件带打开密码，要在表格软件里去掉密码另存再导入：原样读进来再存一次，值与显示格式都不变。 */
    private static byte[] savedAgain(byte[] exported) throws Exception {
        try (XSSFWorkbook workbook = new XSSFWorkbook(new java.io.ByteArrayInputStream(exported));
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            workbook.write(output);
            return output.toByteArray();
        }
    }

    private static void assertExact(String expected, BigDecimal actual) {
        assertEquals(0, new BigDecimal(expected).compareTo(actual), () -> expected + " read back as " + actual);
    }

    private static Map<String, Object> exportRow(String seq, String code, String basis, String basisOutputQty,
                                                 String partial, String qty, String actualQty) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("seq", seq);
        row.put("code", code);
        row.put("name", "货品" + code);
        row.put("consumptionBasis", basis);
        row.put("basisOutputQty", new BigDecimal(basisOutputQty));
        row.put("allowPartialPackage", partial);
        row.put("qty", new BigDecimal(qty));
        row.put("actualQty", actualQty == null ? null : new BigDecimal(actualQty));
        return row;
    }

    /** 最小工作表：表头 + 数据行；列 = 序号/物料编号/数量(旧表头)/[物料名称]。 */
    private static byte[] workbook(String[][] dataRows) throws Exception {
        return workbook(new String[]{"序号", "物料编号", "数量", "物料名称"}, dataRows);
    }

    private static byte[] workbook(String[] headers, String[][] dataRows) throws Exception {
        try (XSSFWorkbook workbook = new XSSFWorkbook();
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            var sheet = workbook.createSheet("配件清单");
            var header = sheet.createRow(0);
            for (int c = 0; c < headers.length; c++) {
                header.createCell(c).setCellValue(headers[c]);
            }
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
