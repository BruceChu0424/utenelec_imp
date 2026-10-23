package com.uten.imp.features.master.goods.importing;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.GoodsRepository;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import java.io.ByteArrayOutputStream;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.util.List;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.mock;

class GoodsImportCustomerLabelsTest {
    @Test void onlyExplicitCustomerGoodsHeadersPopulateTheSeparateNameAndModel() throws Exception {
        for(String header:List.of("客户货品名称","客户品名")) {
            Object row=parseRow(workbook(new String[]{"编号","货品名称","类别",header,"客户型号"},
                    new String[]{"P1","本厂名称","成品","  客户品名  "," C-X  "}));
            assertThat(value(row,"name")).isEqualTo("本厂名称");
            assertThat(value(row,"clientGoodsName")).isEqualTo("客户品名");
            assertThat(value(row,"cNumber")).isEqualTo("C-X");
            assertThat(value(row,"clientGoodsNamePresent")).isEqualTo(true);
        }
    }

    @Test void companyNameAndOrdinaryGoodsNameAreNeverGuessedIntoCustomerGoodsName() throws Exception {
        Object row=parseRow(workbook(new String[]{"编号","货品名称","类别","客户名称","型号"},
                new String[]{"P2","普通货品名称","成品","某客户公司","OWN-MODEL"}));
        assertThat(value(row,"clientGoodsNamePresent")).isEqualTo(false);
        assertThat(value(row,"clientGoodsName")).isIn(null,"");
        assertThat(value(row,"cNumberPresent")).isEqualTo(false);
        assertThat(value(row,"model")).isEqualTo("OWN-MODEL");
    }

    @Test void explicitBlankAndOmittedHeadersRemainDistinguishableForRestoreCompatibility() throws Exception {
        Object row=parseRow(workbook(new String[]{"编号","货品名称","类别","客户货品名称","客户型号"},
                new String[]{"P3","本厂名称","成品","   ",""}));
        assertThat(value(row,"clientGoodsNamePresent")).isEqualTo(true);
        assertThat(value(row,"cNumberPresent")).isEqualTo(true);
        assertThat(value(row,"clientGoodsName")).isIn(null,"");
    }

    @Test void twoCustomerNameColumnsCannotSilentlyChooseTheFirstValue() throws Exception {
        byte[] file=workbook(new String[]{"编号","货品名称","类别","客户货品名称","客户品名"},
                new String[]{"P4","本厂名称","成品","客户甲名称","客户乙名称"});
        assertThatThrownBy(()->parseRow(file)).isInstanceOf(InvocationTargetException.class)
                .hasCauseInstanceOf(ApiException.class);
    }

    private static Object parseRow(byte[] file) throws Exception {
        var service=new GoodsImportService(null,mock(GoodsRepository.class),null,mock(MaterialCategoryRepository.class),
                null,mock(ColorRepository.class),null,mock(UnitRepository.class),mock(EntityManager.class),
                mock(SecurityContextCurrentUser.class),null);
        var method=GoodsImportService.class.getDeclaredMethod("parse",byte[].class);method.setAccessible(true);
        Object parsed=method.invoke(service,(Object)file);
        return ((List<?>)value(parsed,"rows")).getFirst();
    }
    private static Object value(Object object,String name) throws Exception {
        Field field=object.getClass().getDeclaredField(name);field.setAccessible(true);return field.get(object);
    }
    private static byte[] workbook(String[] headers,String[] values) throws Exception {
        try(var book=new XSSFWorkbook();var output=new ByteArrayOutputStream()) {
            var sheet=book.createSheet("货品");var head=sheet.createRow(0);var row=sheet.createRow(1);
            for(int i=0;i<headers.length;i++){head.createCell(i).setCellValue(headers[i]);row.createCell(i).setCellValue(values[i]);}
            book.write(output);return output.toByteArray();
        }
    }
}
