package com.uten.imp.features.master.goods.importing;

import com.uten.imp.features.master.currency.Currency;
import com.uten.imp.features.master.currency.CurrencyRepository;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.io.ByteArrayOutputStream;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class GoodsImportCurrencyTest {
    @Test void exportedCurrencyNameOrMasterCodeResolvesToTheSameUuidWithOneWorkbookLookup() throws Exception {
        var currency = currency("002","美金");
        var repository = mock(CurrencyRepository.class);
        when(repository.findAll()).thenReturn(List.of(currency));
        Object parsed = parse(repository, workbook("美金", "002", ""));
        List<?> rows = value(parsed,"rows");
        assertEquals(currency.getId(),value(rows.get(0),"currencyId"));
        assertEquals(currency.getId(),value(rows.get(1),"currencyId"));
        assertNull(value(rows.get(2),"currencyId"),"An empty historical currency must remain unregistered");
        assertTrue(((List<?>)value(parsed,"headerErrors")).isEmpty());
        verify(repository,times(1)).findAll(); verifyNoMoreInteractions(repository);
    }

    @Test void missingOrAmbiguousCurrencyIsAnErrorAndNeverCreatesOrGuessesAMaster() throws Exception {
        var repository = mock(CurrencyRepository.class);
        when(repository.findAll()).thenReturn(List.of(currency("002","美金"),currency("USD","美金")));
        Object parsed = parse(repository,workbook("美金","不存在"));
        assertEquals(2,((List<?>)value(parsed,"headerErrors")).size());
        for(Object row:(List<?>)value(parsed,"rows")) assertNull(value(row,"currencyId"));
        verify(repository,times(1)).findAll(); verifyNoMoreInteractions(repository);
    }

    private static Currency currency(String code,String name) {
        var value = new Currency(); value.setCode(code); value.setName(name); value.setStatus("使用"); return value;
    }

    private static Object parse(CurrencyRepository repository,byte[] bytes) throws Exception {
        var service = new GoodsImportService(null,null,null,null,null,null,null,null,null,null,null);
        ReflectionTestUtils.setField(service,"currencyRepo",repository);
        return ReflectionTestUtils.invokeMethod(service,"parse",bytes);
    }

    @SuppressWarnings("unchecked") private static <T> T value(Object object,String name) throws Exception {
        var field=object.getClass().getDeclaredField(name); field.setAccessible(true); return (T)field.get(object);
    }

    private static byte[] workbook(String... currencies) throws Exception {
        try(var book = new XSSFWorkbook(); var output = new ByteArrayOutputStream()) {
            var sheet=book.createSheet("货品"); var header=sheet.createRow(0);
            header.createCell(0).setCellValue("货品名称"); header.createCell(1).setCellValue("类别"); header.createCell(2).setCellValue("币种");
            for(int i=0;i<currencies.length;i++) {
                var row=sheet.createRow(i+1); row.createCell(0).setCellValue("货品"+i);
                row.createCell(1).setCellValue("成品"); row.createCell(2).setCellValue(currencies[i]);
            }
            book.write(output); return output.toByteArray();
        }
    }
}
