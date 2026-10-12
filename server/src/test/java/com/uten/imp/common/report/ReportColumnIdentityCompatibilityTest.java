package com.uten.imp.common.report;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import static org.assertj.core.api.Assertions.assertThat;

class ReportColumnIdentityCompatibilityTest {
    @ParameterizedTest @ValueSource(strings={"finance","sales","purchase","subcontract","production","stock"})
    void oldConstructorsAndUnitFluentsKeepTheIdentityContract(String family)throws Exception{
        Class<?> type=Class.forName("com.uten.imp.features."+family+".report.ReportColumn");
        Object four=type.getConstructor(String.class,String.class,String.class,Integer.class).newInstance("qty","数量","number",null);
        Object six=type.getConstructor(String.class,String.class,String.class,Integer.class,String.class,String.class)
                .newInstance("qty","数量","number",null,"合计数量","unitName");
        Object eight=type.getConstructor(String.class,String.class,String.class,Integer.class,String.class,String.class,String.class,String.class)
                .newInstance("qty","数量","number",null,"合计数量","unitName",null,"unitName");
        for(Object old:new Object[]{four,six,eight})assertThat(type.getMethod("totalGroupIdentityKey").invoke(old)).isNull();
        Object grouped=type.getMethod("totaled",String.class,String.class,String.class).invoke(four,"合计数量","unitName","__unitId");
        Object rowUnit=type.getMethod("withUnitKey",String.class).invoke(grouped,"unitName");
        Object fixedUnit=type.getMethod("withUnitLabel",String.class).invoke(grouped,"个");
        for(Object current:new Object[]{grouped,rowUnit,fixedUnit}){
            assertThat(type.getMethod("totalGroupIdentityKey").invoke(current)).isEqualTo("__unitId");
            assertThat(type.getMethod("totalGroupKey").invoke(current)).isEqualTo("unitName");
        }
    }
}
