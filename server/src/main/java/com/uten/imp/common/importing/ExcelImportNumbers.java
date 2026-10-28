package com.uten.imp.common.importing;

import org.apache.poi.ss.usermodel.Cell;
import org.apache.poi.ss.usermodel.CellType;
import org.apache.poi.xssf.usermodel.XSSFCell;

import java.math.BigDecimal;
import java.math.MathContext;
import java.math.RoundingMode;

/** Decimal ingestion for native Excel numeric cells, independent of their display format. */
public final class ExcelImportNumbers {
    private static final MathContext EXCEL_PRECISION = new MathContext(15, RoundingMode.HALF_EVEN);

    private ExcelImportNumbers() { }

    /**
     * Keeps valid raw decimals intact. An over-scale value may lose only a binary
     * representation tail: its Excel 15-digit value must fit the caller's scale
     * and be within one IEEE-754 ULP of the raw value. Explicit text and edited
     * text must bypass this method and remain exact for business validation.
     */
    public static String numericText(Cell cell, int maxScale) {
        if (maxScale < 0 || maxScale > 18) throw new IllegalArgumentException("unsupported decimal scale");
        CellType type = cell.getCellType() == CellType.FORMULA
                ? cell.getCachedFormulaResultType() : cell.getCellType();
        if (type != CellType.NUMERIC) throw new IllegalArgumentException("numeric Excel cell required");
        String raw = cell instanceof XSSFCell xssf
                ? xssf.getRawValue() : BigDecimal.valueOf(cell.getNumericCellValue()).toPlainString();
        if (raw == null || raw.isBlank()) return raw;
        BigDecimal value;
        try {
            value = new BigDecimal(raw);
        } catch (NumberFormatException invalid) {
            return raw;
        }
        // Leave out-of-contract exponents/lengths to the caller's normal error
        // reporting; do not expand them while examining a representation tail.
        if (value.precision() > 64 || value.scale() < -18 || value.scale() > 64) return raw;
        BigDecimal normalized = value.stripTrailingZeros();
        if (normalized.scale() <= maxScale) return raw;
        BigDecimal candidate = normalized.round(EXCEL_PRECISION).stripTrailingZeros();
        if (candidate.scale() > maxScale) return raw;
        double binary = value.doubleValue();
        if (!Double.isFinite(binary)) return raw;
        BigDecimal tolerance = new BigDecimal(Math.ulp(binary));
        if (value.subtract(candidate).abs().compareTo(tolerance) > 0) return raw;
        return candidate.toPlainString();
    }
}
