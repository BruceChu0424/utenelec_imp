package com.uten.imp.features.production.quality;

import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.sql.DriverManager;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.postgresql.PostgreSQLContainer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Executes the actual pending-source quantity expression with independent exact JDBC scalars.
 * Source joins/permissions remain covered by the complete FQC and pending-queue callers. */
@Testcontainers(disabledWithoutDocker=true)
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ProductionFqcPendingQuantityPostgresTest {
    @Container static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");

    private record SumVector(List<String> quantities,String expected) { }

    @Test void actualSheetSummaryKeepsIntegerZerosZeroAndEveryFractionalDigit() throws Exception {
        String sql=org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                ProductionFqcInspectionService.class,"sheetSql","TRUE");
        assertThat(sql).isNotNull();
        String marker="AS unit_name,";
        int start=sql.indexOf(marker);assertThat(start).isGreaterThanOrEqualTo(0);start+=marker.length();
        int end=sql.indexOf("AS qty_text",start);assertThat(end).isGreaterThan(start);
        String expression=sql.substring(start,end).trim();
        String statement="SELECT "+expression+" FROM (SELECT value AS reported_qty,0::numeric AS passed_qty,"
                +"0::numeric AS failed_qty FROM unnest(CAST(? AS numeric[])) source(value)) pending_inspection";
        try(var connection=DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
                var query=connection.prepareStatement(statement)){
            for(var vector:List.of(new SumVector(List.of("0"),"0"),new SumVector(List.of("20"),"20"),
                    new SumVector(List.of("2000"),"2000"),
                    new SumVector(List.of("0.000000000000000000000001"),"0.000000000000000000000001"),
                    new SumVector(List.of("3","3","4","5","5"),"20"),
                    new SumVector(List.of("1.2300","0.004500"),"1.2345"),new SumVector(List.of(),null))){
                var values=connection.createArrayOf("numeric",vector.quantities().stream().map(BigDecimal::new).toArray());
                try{
                    query.setArray(1,values);
                    try(var result=query.executeQuery()){
                        assertThat(result.next()).isTrue();
                        assertThat(result.getString(1)).as(vector.quantities().toString()).isEqualTo(vector.expected());
                        assertThat(result.next()).isFalse();
                    }
                }finally{values.free();}
            }
        }
    }

    @Test void sourcePlanKeepsWholeTensAndTheLastFractionalUnitWithoutRounding() throws Exception {
        var access=mock(ProductionFqcTaskAccessPolicy.class);
        when(access.canAccessQualityPool()).thenReturn(true);
        var service=ProductionFqcInspectionServiceTest.service(mock(EntityManager.class),
                mock(ProductionDocumentAccessPolicy.class),access);
        var plan=service.pendingPlans().stream().filter(item->item.key().equals("FQC")).findFirst().orElseThrow();
        String sql=plan.sql();
        int start=sql.indexOf("concat_ws(' ',");
        int end=sql.indexOf(" AS pending_qty",start);
        assertThat(start).isGreaterThanOrEqualTo(0);
        assertThat(end).isGreaterThan(start);
        String expression=sql.substring(start,end);
        String statement="SELECT "+expression+" FROM (SELECT CAST(? AS numeric) reported_qty,CAST(? AS numeric) passed_qty,"
                +"CAST(? AS numeric) failed_qty,CAST(? AS text) unit_name) q";
        try(var connection=DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
            var query=connection.prepareStatement(statement)) {
            for(var row:List.of(
                    List.of("30","0","0","个","30 个"),
                    List.of("12","2","0","个","10 个"),
                    List.of("1","0.999999999999999999999999","0","个","0.000000000000000000000001 个"),
                    List.of("0.000000000000000000000001","0","0","m","0.000000000000000000000001 m"),
                    List.of("1.234500","0","0","m","1.2345 m"))) {
                for(int index=0;index<3;index++)query.setBigDecimal(index+1,new BigDecimal(row.get(index)));
                query.setString(4,row.get(3));
                try(var result=query.executeQuery()) {
                    assertThat(result.next()).isTrue();
                    assertThat(result.getString(1)).isEqualTo(row.get(4));
                    assertThat(result.next()).isFalse();
                }
            }
        }
    }
}
