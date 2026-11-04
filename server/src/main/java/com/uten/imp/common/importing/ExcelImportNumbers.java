package com.uten.imp.common.importing;

import org.apache.poi.ss.usermodel.Cell;
import org.apache.poi.ss.usermodel.CellType;
import org.apache.poi.xssf.usermodel.XSSFCell;

import java.math.BigDecimal;

/** Decimal ingestion for native Excel numeric cells, independent of their display format. */
public final class ExcelImportNumbers {
    private ExcelImportNumbers() { }

    /**
     * Preserves the stored numeric decimal, including a binary-looking tail.
     * The caller validates its supported range and keeps the original cell for
     * correction. A display mask or proximity to another decimal never grants
     * permission to round financial or other business input.
     */
    public static String numericText(Cell cell, int maxScale) {
        if (maxScale < 0 || maxScale > 30) throw new IllegalArgumentException("unsupported decimal scale");
        CellType type = cell.getCellType() == CellType.FORMULA
                ? cell.getCachedFormulaResultType() : cell.getCellType();
        if (type != CellType.NUMERIC) throw new IllegalArgumentException("numeric Excel cell required");
        String raw = cell instanceof XSSFCell xssf
                ? xssf.getRawValue() : BigDecimal.valueOf(cell.getNumericCellValue()).toPlainString();
        if (raw == null || raw.isBlank()) return raw;
        return raw;
    }
}
