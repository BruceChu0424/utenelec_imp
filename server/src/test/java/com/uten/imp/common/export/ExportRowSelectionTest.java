package com.uten.imp.common.export;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.*;
import java.util.concurrent.CancellationException;
import java.util.stream.IntStream;
import static org.assertj.core.api.Assertions.*;

class ExportRowSelectionTest {
    private static final List<ExportColumn> COLUMNS=List.of(new ExportColumn("code","编号",ExportColumn.TEXT),
            new ExportColumn("qty","数量",ExportColumn.QTY),new ExportColumn("name","名称",ExportColumn.TEXT));
    private static TableColumnProjection projection(List<Map<String,String>> selected){
        return new TableColumnProjection("fixture","view_sales",List.of(new TableColumnProjection.Column("code",null,null,null,null)),selected);
    }
    @Test void extremeNumericExponentsRemainCompactAndNeverExpandIntoOutputValues() {
        var selection=new ExportRowSelection(projection(List.of(Map.of("qty","1e999999999"))));
        assertThat(selection.select(COLUMNS,List.of(Map.of("qty",new BigDecimal("1"))))).isEmpty();
        assertThatThrownBy(selection::verifyComplete).isInstanceOf(ApiException.class);
        var equal=new ExportRowSelection(projection(List.of(Map.of("qty","1000.000"))));
        assertThat(equal.select(COLUMNS,List.of(Map.of("qty",new BigDecimal("1E+3"))))).hasSize(1);
        equal.verifyComplete();
    }
    @AfterEach void clearInterrupt(){Thread.interrupted();}
    @Test void nullSelectionKeepsCompleteAuthoritativeSource(){
        var selection=new ExportRowSelection(projection(null));
        List<Map<String,Object>> rows=List.of(Map.of("code","001"));
        assertThat(selection.select(COLUMNS,rows)).isSameAs(rows);selection.verifyComplete();
    }
    @Test void identitiesAndExactNumericFactsSelectServerRowsWithoutRewritingAnyCells(){
        String id=UUID.randomUUID().toString();
        var selection=new ExportRowSelection(projection(List.of(Map.of("@id",id,"code","001","qty","1.00"))));
        Map<String,Object> source=new LinkedHashMap<>(Map.of("_platformRecordId",id,"code","001","qty",new BigDecimal("1.0"),"name","服务器原值"));
        assertThat(selection.select(COLUMNS,List.of(Map.of("_platformRecordId",UUID.randomUUID().toString(),"code","001","qty",1),source)))
                .singleElement().isSameAs(source);
        selection.verifyComplete();
        assertThat(source).containsEntry("name","服务器原值").containsEntry("qty",new BigDecimal("1.0")).containsEntry("code","001");
    }
    @Test void textIdentifiersNeverUseNumericCanonicalization(){
        var selection=new ExportRowSelection(projection(List.of(Map.of("code","001"))));
        assertThat(selection.select(COLUMNS,List.of(Map.of("code","1"),Map.of("code",1)))).isEmpty();
        assertThatThrownBy(selection::verifyComplete).isInstanceOf(ApiException.class);
    }
    @Test void clientChangedFactsCannotReplaceCurrentServerValues(){
        var selection=new ExportRowSelection(projection(List.of(Map.of("code","001","name","客户端伪造值"))));
        assertThat(selection.select(COLUMNS,List.of(Map.of("code","001","name","服务器原值")))).isEmpty();
        assertThatThrownBy(selection::verifyComplete).isInstanceOf(ApiException.class).hasMessageContaining("已变化");
    }
    @Test void emptyMalformedMixedSchemasAndDuplicateSelectorsFailClosed(){
        assertThatThrownBy(()->new ExportRowSelection(projection(List.of()))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->new ExportRowSelection(projection(List.of(Map.of())))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->new ExportRowSelection(projection(List.of(Map.of("code","1"),Map.of("name","2")))))
                .isInstanceOf(ApiException.class).hasMessageContaining("字段不一致");
        var duplicates=new ExportRowSelection(projection(List.of(Map.of("code","001"),Map.of("code","001"))));
        assertThatThrownBy(()->duplicates.select(COLUMNS,List.of())).isInstanceOf(ApiException.class).hasMessageContaining("身份重复");
    }
    @Test void duplicatesInLaterAuthoritativePagesAndMissingFinalMemberAreRejected(){
        var selected=new ExportRowSelection(projection(List.of(Map.of("code","001"))));
        selected.select(COLUMNS,List.of(Map.of("code","001")));
        assertThatThrownBy(()->selected.select(COLUMNS,List.of(Map.of("code","001"))))
                .isInstanceOf(ApiException.class).hasMessageContaining("身份不唯一");
        var missing=new ExportRowSelection(projection(List.of(Map.of("code","001"),Map.of("code","002"))));
        missing.select(COLUMNS,List.of(Map.of("code","001")));
        assertThatThrownBy(missing::verifyComplete).isInstanceOf(ApiException.class).hasMessageContaining("已变化");
    }
    @Test void fiftyThousandMembersRemainCompleteAcrossThousandRowPages(){
        var selected=IntStream.range(0,50000).mapToObj(i->Map.of("code",Integer.toString(i))).toList();
        var selection=new ExportRowSelection(projection(selected)); int count=0;
        for(int start=0;start<50000;start+=1000){
            List<Map<String,Object>> rows=IntStream.range(start,start+1000).mapToObj(i->Map.<String,Object>of("code",Integer.toString(i))).toList();
            count+=selection.select(COLUMNS,rows).size();
        }
        assertThat(count).isEqualTo(50000);selection.verifyComplete();
    }
    @Test void interruptionStopsSelectionAndDoesNotContaminateTheNextOperation(){
        var selection=new ExportRowSelection(projection(List.of(Map.of("code","001"))));
        try {
            Thread.currentThread().interrupt();
            assertThatThrownBy(()->selection.select(COLUMNS,List.of(Map.of("code","001")))).isInstanceOf(CancellationException.class);
        } finally {Thread.interrupted();}
        var next=new ExportRowSelection(projection(List.of(Map.of("code","001"))));
        assertThat(next.select(COLUMNS,List.of(Map.of("code","001")))).hasSize(1);next.verifyComplete();
    }
    @Test void selectorsCannotProbeHiddenBusinessFieldsEvenWhenAnAuthorizedSourceContainsThem(){
        var hidden=new ExportRowSelection(projection(List.of(Map.of("bankAccountNo","private"))));
        assertThatThrownBy(()->hidden.select(COLUMNS,List.of(Map.of("code","001","bankAccountNo","private"))))
                .isInstanceOf(ApiException.class).hasMessageContaining("不可输出");
    }
    @Test void missingNullableCellsMatchOnlyAnExplicitNullSelector(){
        Map<String,String> nullable=new LinkedHashMap<>();nullable.put("code","001");nullable.put("name",null);
        var selection=new ExportRowSelection(projection(List.of(nullable)));
        var source=Map.<String,Object>of("code","001");
        assertThat(selection.select(COLUMNS,List.of(source))).containsExactly(source);selection.verifyComplete();
        var nonnull=new ExportRowSelection(projection(List.of(Map.of("code","001","name","non-null"))));
        assertThat(nonnull.select(COLUMNS,List.of(source))).isEmpty();
        assertThatThrownBy(nonnull::verifyComplete).isInstanceOf(ApiException.class);
    }
    @Test void exactDecimalSelectorDoesNotChooseTheNeighborRoundedToTheSameDouble(){
        var selection=new ExportRowSelection(projection(List.of(Map.of("qty","90071992547409.0001"))));
        var exact=Map.<String,Object>of("qty",new BigDecimal("90071992547409.0001"));
        var rounded=Map.<String,Object>of("qty",new BigDecimal("90071992547409.0000"));
        assertThat(selection.select(COLUMNS,List.of(rounded,exact))).singleElement().isSameAs(exact);selection.verifyComplete();
    }
}
