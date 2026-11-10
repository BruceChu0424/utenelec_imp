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
    @Test void warehouseWorkshopSelectorExportsTheAuthoritativeDisplayNameAndNeverBroadensOtherSchemas() {
        var columns=List.of(new ExportColumn("workshopDepartmentName","车间","text"));
        var projection=new TableColumnProjection("master.warehouses","master_warehouse",
                List.of(column("workshopDepartmentId","车间")));
        var result=service.project(columns,List.of(Map.of("workshopDepartmentName","铜柱车间")),projection,"master_warehouse");
        assertThat(result.columns()).extracting(ExportColumn::key).containsExactly("workshopDepartmentName");
        assertThat(result.rows().getFirst()).containsEntry("workshopDepartmentName","铜柱车间");
        assertThatThrownBy(()->service.project(List.of(new ExportColumn("name","名称","text")),List.of(),projection,"master_goods"))
                .isInstanceOf(ApiException.class);
        verifyNoInteractions(platform);
    }
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
    /** 2026-10-20：BOM 组装表「来源」列与货架标签页「实际仓库」列的表名与导出列名不同名，必须走别名而不是 409。 */
    @Test void sourceAndWarehouseColumnAliasesResolveToExportSchemaKeys() {
        var bom=service.project(List.of(new ExportColumn("sourceType","来源","text"),new ExportColumn("qty","数量","number")),
                List.of(),new TableColumnProjection("t",null,List.of(column("source","来源"),column("qty","数量"))),"view_master");
        assertThat(bom.columns()).extracting(ExportColumn::key).containsExactly("sourceType","qty");
        var shelf=service.project(List.of(new ExportColumn("warehouseName","实际仓库","text")),
                List.of(),new TableColumnProjection("t",null,List.of(column("warehouse","实际仓库"))),"view_warehouse");
        assertThat(shelf.columns()).extracting(ExportColumn::key).containsExactly("warehouseName");
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
    @Test void exactNumberPriceKeepsNumericFactsForDisplayCalculationsAndPdfText() {
        UUID id=UUID.randomUUID();
        BigDecimal price = new BigDecimal("0.9141234567");
        var definition=new Definition(id,"view_goods","价格两倍","CALCULATED",false,
            new Formula(new Operand(null,"price",null),List.of(new Step("MULTIPLY",new Operand(null,null,"2")))),0,0);
        when(platform.definitionsByIds("view_goods",List.of(id))).thenReturn(List.of(definition));
        when(platform.evaluateDisplayRows(eq("view_goods"),eq(List.of(id)),anyList()))
            .thenReturn(List.of(Map.of(id,"1.8282469134")));
        var column = new ExportColumn("price","价格",ExportColumn.EXACT_NUMBER);
        var result=service.project(List.of(column), List.of(Map.of("price",price)),
            new TableColumnProjection("t","view_goods",List.of(column("price","价格"),column("platform:"+id,"价格两倍"))),"view_goods");
        assertThat(result.columns().getFirst().type()).isEqualTo(ExportColumn.EXACT_NUMBER);
        assertThat(result.rows().getFirst()).containsEntry("price",price).containsEntry("platform:"+id,"1.8282469134");
        verify(platform).evaluateDisplayRows("view_goods",List.of(id),List.of(Map.of("price",price)));
        assertThat(ExportCellValues.display(column,result.rows().getFirst())).isEqualTo("0.9141234567");
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
    @Test void privateRelatedCodesRemainTextAndUseCurrentAuthorizedRelationDuringExport() {
        UUID id=UUID.randomUUID(),record=UUID.randomUUID();
        var definition=new Definition(id,"master_goods","我的模具编号","RELATED",false,null,0,0,"mouldCode");
        when(platform.definitionsByIds("master_goods",List.of(id))).thenReturn(List.of(definition));
        when(platform.read(eq("master_goods"),any())).thenReturn(List.of(new Row(record,0,false,
            List.of(new Cell(id,"00012",definition,false,false,null)))));
        var projected=service.project(List.of(),List.of(Map.of("_platformRecordId",record)),
            new TableColumnProjection("t","master_goods",List.of(column("platform:"+id,"我的模具编号"))),"master_goods");
        assertThat(projected.columns().getFirst().type()).isEqualTo("text");
        assertThat(projected.rows().getFirst().get("platform:"+id)).isEqualTo("00012");
    }
}
