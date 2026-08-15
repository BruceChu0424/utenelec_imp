package com.uten.imp.features.master.goods.importing;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.apache.poi.openxml4j.util.ZipSecureFile;
import org.apache.poi.ss.usermodel.Cell;
import org.apache.poi.ss.usermodel.CellType;
import org.apache.poi.ss.usermodel.Row;
import org.apache.poi.ss.usermodel.Sheet;
import org.apache.poi.ss.usermodel.Workbook;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/** Fail-closed resource and active-content boundary for goods-import OOXML. */
final class GoodsImportWorkbookSecurity {

    static final int MAX_COMPRESSED_BYTES = 10 * 1024 * 1024;
    private static final long MAX_TOTAL_EXPANDED_BYTES = 64L * 1024 * 1024;
    private static final long MAX_ENTRY_EXPANDED_BYTES = 32L * 1024 * 1024;
    private static final int MAX_ARCHIVE_ENTRIES = 512;
    private static final long MAX_EXPANSION_RATIO = 50;
    private static final int MAX_SHEETS = 4;
    private static final int MAX_ROWS = 20_000;
    private static final int MAX_COLUMNS = 64;
    private static final int MAX_CELLS = 250_000;
    private static final int MAX_CELL_CHARACTERS = 4_096;

    private static final Set<String> REQUIRED_ENTRIES = Set.of(
            "[Content_Types].xml",
            "_rels/.rels",
            "xl/workbook.xml",
            "xl/_rels/workbook.xml.rels");

    private GoodsImportWorkbookSecurity() {
    }

    static void inspectArchive(byte[] xlsx) {
        if (xlsx.length > MAX_COMPRESSED_BYTES) {
            throw rejected("Excel 文件超过 10 MiB，请拆分为多个批次后重试");
        }

        // POI's limits are process-wide. Re-assert the reviewed ceiling before
        // every parse so a future feature cannot silently relax this import.
        synchronized (ZipSecureFile.class) {
            ZipSecureFile.setMinInflateRatio(0.02d);
            ZipSecureFile.setMaxEntrySize(128L * 1024 * 1024);
            ZipSecureFile.setMaxFileCount(4_096);
            ZipSecureFile.setMaxTextSize(10L * 1024 * 1024);
        }

        Set<String> names = new HashSet<>();
        long totalExpanded = 0;
        int entryCount = 0;
        byte[] buffer = new byte[16 * 1024];

        try (ZipInputStream archive = new ZipInputStream(new ByteArrayInputStream(xlsx))) {
            ZipEntry entry;
            while ((entry = archive.getNextEntry()) != null) {
                entryCount++;
                if (entryCount > MAX_ARCHIVE_ENTRIES) {
                    throw rejected("Excel 压缩包条目过多，请仅保留商品导入工作表");
                }

                String name = entry.getName();
                validateEntryName(name, names);
                if (entry.getMethod() != ZipEntry.STORED && entry.getMethod() != ZipEntry.DEFLATED) {
                    throw rejected("Excel 使用了不支持的压缩方式");
                }
                if (entry.getSize() > MAX_ENTRY_EXPANDED_BYTES) {
                    throw rejected("Excel 内部单个内容过大，请拆分后重试");
                }

                long entryExpanded = 0;
                int read;
                while ((read = archive.read(buffer)) != -1) {
                    entryExpanded += read;
                    totalExpanded += read;
                    if (entryExpanded > MAX_ENTRY_EXPANDED_BYTES
                            || totalExpanded > MAX_TOTAL_EXPANDED_BYTES) {
                        throw rejected("Excel 解压后的内容过大，请拆分后重试");
                    }
                    if (totalExpanded > (long) xlsx.length * MAX_EXPANSION_RATIO) {
                        throw rejected("Excel 压缩比例异常，已拒绝解析");
                    }
                }
                archive.closeEntry();
            }
        } catch (ApiException error) {
            throw error;
        } catch (IOException | RuntimeException error) {
            throw rejected("Excel 压缩包损坏或格式异常，请另存为普通 .xlsx 后重试");
        }

        if (!names.containsAll(REQUIRED_ENTRIES)) {
            throw rejected("无法解析 Excel 文件：缺少必要结构，请另存为未加密的 .xlsx 后重试");
        }
    }

    static void inspectWorkbook(Workbook workbook) {
        int sheetCount = workbook.getNumberOfSheets();
        if (sheetCount < 1) {
            throw rejected("Excel 文件不包含工作表，请使用货品导出格式后重试");
        }
        if (sheetCount > MAX_SHEETS) {
            throw rejected("Excel 工作表数量超出允许范围，请仅保留商品导入工作表");
        }

        Sheet first = workbook.getSheetAt(0);
        if (first.getLastRowNum() >= MAX_ROWS || first.getPhysicalNumberOfRows() > MAX_ROWS) {
            throw rejected("Excel 商品行超过 20000 行，请拆分为多个批次后重试");
        }

        int cells = 0;
        for (Row row : first) {
            if (row.getLastCellNum() > MAX_COLUMNS || row.getPhysicalNumberOfCells() > MAX_COLUMNS) {
                throw rejected("Excel 列数超过 64 列，请使用标准商品导入模板");
            }
            cells += row.getPhysicalNumberOfCells();
            if (cells > MAX_CELLS) {
                throw rejected("Excel 单元格数量过多，请拆分为多个批次后重试");
            }
            for (Cell cell : row) {
                if (cell.getCellType() == CellType.FORMULA) {
                    throw rejected("商品导入不执行公式，请先将公式复制并粘贴为值");
                }
                if (cell.getCellType() == CellType.STRING
                        && cell.getStringCellValue().length() > MAX_CELL_CHARACTERS) {
                    throw rejected("Excel 单元格文本过长，请检查后重试");
                }
            }
        }
    }

    private static void validateEntryName(String name, Set<String> names) {
        if (name == null || name.isEmpty() || name.length() > 255
                || name.startsWith("/") || name.contains("\\") || name.contains(":")
                || name.indexOf('\0') >= 0) {
            throw rejected("Excel 压缩包包含非法路径");
        }
        String[] segments = name.split("/", -1);
        for (int index = 0; index < segments.length; index++) {
            String segment = segments[index];
            boolean trailingDirectoryMarker = index == segments.length - 1 && segment.isEmpty();
            if (!trailingDirectoryMarker && (segment.isEmpty() || ".".equals(segment) || "..".equals(segment))) {
                throw rejected("Excel 压缩包包含非法路径");
            }
        }
        if (!names.add(name)) {
            throw rejected("Excel 压缩包包含重复条目");
        }

        String lower = name.toLowerCase(Locale.ROOT);
        if (lower.endsWith(".bin")
                || lower.startsWith("xl/externallinks/")
                || lower.startsWith("xl/embeddings/")
                || lower.startsWith("xl/oleobjects/")
                || lower.startsWith("xl/activex/")
                || lower.startsWith("xl/querytables/")
                || lower.startsWith("customxml/")
                || lower.equals("xl/connections.xml")) {
            throw rejected("商品导入不接受宏、外部链接或嵌入对象，请另存为普通 .xlsx");
        }
    }

    private static ApiException rejected(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }
}
