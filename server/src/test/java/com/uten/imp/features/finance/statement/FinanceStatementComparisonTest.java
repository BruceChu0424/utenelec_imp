package com.uten.imp.features.finance.statement;

import com.uten.imp.features.finance.report.FinanceTemplateSourceReader.Cell;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class FinanceStatementComparisonTest {
    @Test void everyOriginalDecimalDigitMattersEvenWhereTheDisplayWouldPreviouslyRoundThemEqual(){
        String original="90071992547409.123456789012345678901234";
        var cell=new Cell(7,original,"NUMBER",original);
        assertThat(FinanceStatementComparisonService.compareCell(cell,original,original,"money")).isEqualTo("EQUAL");
        assertThat(FinanceStatementComparisonService.compareCell(cell,original,"90071992547409.123456789012345678901235","money")).isEqualTo("DIFFERENT");
        assertThat(FinanceStatementComparisonService.compareCell(cell,"1.0000","1","number")).isEqualTo("EQUAL");
    }
    @Test void missingAndFormulaErrorAreNotAProvedZero(){
        assertThat(FinanceStatementComparisonService.compareCell(new Cell(7,"#DIV/0!","ERROR",null),"#DIV/0!","0","money")).isEqualTo("PENDING");
        assertThat(FinanceStatementComparisonService.compareCell(null,"","0","money")).isEqualTo("PENDING");
        assertThat(FinanceStatementComparisonService.compareCell(new Cell(7,"0","NUMBER","0"),"0",null,"money")).isEqualTo("PENDING");
        assertThat(FinanceStatementComparisonService.compareCell(null,"",null,"text")).isEqualTo("EQUAL");
    }
    @Test void equivalentUnambiguousDatesMatchAndInvalidDatesRemainPending(){
        assertThat(FinanceStatementComparisonService.compareCell(null,"2026/9/5","2026-09-05","date")).isEqualTo("EQUAL");
        assertThat(FinanceStatementComparisonService.compareCell(null,"2026年9月5日","2026-09-06","date")).isEqualTo("DIFFERENT");
        assertThat(FinanceStatementComparisonService.compareCell(null,"2026/2/31","2026-02-28","date")).isEqualTo("PENDING");
    }
}
