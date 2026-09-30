package com.uten.imp.common.export;

import com.uten.imp.common.platformcolumns.PlatformColumnContracts.*;
import com.uten.imp.common.platformcolumns.PlatformColumnService;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ExportTableProjectionServiceTest {
    private final PlatformColumnService platform=mock(PlatformColumnService.class);
    private final ExportTableProjectionService service=new ExportTableProjectionService(platform);
    private TableColumnProjection.Column column(String key,String name){return new TableColumnProjection.Column(key,name,120d,"money",null);}
    @Test void visibleOrderLabelsAndAliasesComeFromCurrentHeaderWithoutRestoringHiddenColumns() {
        var columns=List.of(new ExportColumn("name","名称","text"),new ExportColumn("colorName","颜色","text"),new ExportColumn("qty","数量","number"));
        var projection=new TableColumnProjection("test","view_master",List.of(column("qty","本次数量"),column("colorLegacyId","颜色")));
        var result=service.project(columns,List.of(Map.of("name","G","colorName","白","qty",3)),projection,"view_master");
        assertThat(result.columns()).extracting(ExportColumn::key).containsExactly("qty","colorName");
        assertThat(result.columns()).extracting(ExportColumn::label).containsExactly("本次数量","颜色");
        assertThat(result.columns()).allMatch(c->c.width().equals(120d));
        verifyNoInteractions(platform);
    }
    @Test void unavailableBuiltinAndForeignResourceProjectionFailClosed() {
        var available=List.of(new ExportColumn("qty","数量","number"));
        assertThatThrownBy(()->service.project(available,List.of(),new TableColumnProjection("t","view_sales",List.of(column("price","单价"))),"view_sales"))
            .isInstanceOf(ApiException.class);
        UUID id=UUID.randomUUID();
        assertThatThrownBy(()->service.project(available,List.of(),new TableColumnProjection("t","master_client",List.of(column("platform:"+id,"资料"))),"master_goods"))
            .isInstanceOf(ApiException.class);
        verifyNoInteractions(platform);
    }
    @Test void displayCalculationUsesServerDefinitionAndOnlyAuthorizedSourceFacts() {
        UUID id=UUID.randomUUID();
        var definition=new Definition(id,"view_sales","数量倍数","CALCULATED",false,
            new Formula(new Operand(null,"qty",null),List.of(new Step("MULTIPLY",new Operand(null,null,"2")))),0,0);
        when(platform.definitionsByIds("view_sales",List.of(id))).thenReturn(List.of(definition));
        when(platform.evaluateDisplayRows(eq("view_sales"),eq(List.of(id)),anyList())).thenReturn(List.of(Map.of(id,"6")));
        var result=service.project(List.of(new ExportColumn("qty","数量","number"),new ExportColumn("code","编号","text"),new ExportColumn("docSeq","序号","number")),
            List.of(Map.of("qty",new BigDecimal("3"),"price",new BigDecimal("999"),"code","000017","docSeq",1)),
            new TableColumnProjection("t","view_sales",List.of(column("platform:"+id,"数量倍数"))),"view_sales");
        assertThat(result.rows().getFirst()).containsEntry("platform:"+id,"6");
        assertThat(result.columns().getFirst().type()).isEqualTo("qty");
        verify(platform).evaluateDisplayRows("view_sales",List.of(id),List.of(Map.of("qty",new BigDecimal("3"))));
    }
    @Test void storedTextColumnKeepsLeadingZeroesAndReadsOnlyExportedRecordIds() {
        UUID id=UUID.randomUUID(),record=UUID.randomUUID();
        var definition=new Definition(id,"master_goods","外部编码","TEXT",false,null,0,0);
        when(platform.definitionsByIds("master_goods",List.of(id))).thenReturn(List.of(definition));
        when(platform.read(eq("master_goods"),any())).thenReturn(List.of(new Row(record,1,false,
            List.of(new Cell(id,"0017",definition,false,true,null)))));
        var projected=service.project(List.of(new ExportColumn("name","货品","text")),
            List.of(Map.of("name","G","_platformRecordId",record)),
            new TableColumnProjection("t","master_goods",List.of(column("platform:"+id,"外部编码"))),"master_goods");
        assertThat(projected.columns().getFirst().type()).isEqualTo("text");
        assertThat(projected.rows().getFirst().get("platform:"+id)).isEqualTo("0017");
        verify(platform).read("master_goods",new BatchRead(List.of(record),List.of(id)));
    }
}
