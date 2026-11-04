package com.uten.imp.features.stock.valuation;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.finance.BusinessPrecisionRequiredException;
import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

/** Same cumulative-source vectors for the public Java arithmetic and the real installed SQL proof. */
class InventoryValuePrecisionContractPostgresTest {
    private static final ObjectMapper JSON=new ObjectMapper();
    private static JsonNode contract() throws Exception {
        return JSON.readTree(Files.readString(Path.of("../contracts/inventory-value-precision/v2.json")));
    }
    private static BigDecimal decimal(JsonNode item,String field){return new BigDecimal(item.path(field).asText());}
    private static Map<String,BusinessPrecisionContext.Choice> choices(JsonNode item){
        return item.has("choice")?Map.of("stock.value.interval",new BusinessPrecisionContext.Choice(
            item.path("choice").path("scale").asInt(),item.path("choice").path("rounding").asText())):Map.of();
    }
    @Test void javaCumulativeBookValuesRetainExactDigitsAndRequireAnActualChoice() throws Exception {
        for(var item:contract().path("cases"))try(var policy=BusinessPrecisionContext.use(choices(item))){
            java.util.function.Supplier<BigDecimal> calculation=()->item.path("precisionVersion").asInt()==1
                ?ValueMath.interval(decimal(item,"value"),decimal(item,"from"),decimal(item,"to"),decimal(item,"denominator"))
                :MoneyPolicy.bookValueSlice(decimal(item,"value"),decimal(item,"denominator"),decimal(item,"from"),decimal(item,"to").subtract(decimal(item,"from")));
            if(item.has("required")){
                Throwable failure=catchThrowable(calculation::get);
                assertThat(failure).as(item.path("id").asText()).isInstanceOf(BusinessPrecisionRequiredException.class);
                assertThat(((BusinessPrecisionRequiredException)failure).details()).containsEntry("reason",item.path("required").asText());
            }else assertThat(calculation.get()).as(item.path("id").asText()).isEqualByComparingTo(item.path("expected").asText());
        }
    }
    @Test void anExplicitChoiceCannotAllocateMoreThanTheActualSourceBudget() throws Exception {
        try(var policy=BusinessPrecisionContext.use(Map.of("stock.value.interval",new BusinessPrecisionContext.Choice(0,"HALF_UP")))){
            for(String source:new String[]{"0.6","-0.6"}){
                Throwable failure=catchThrowable(()->MoneyPolicy.bookValueSlice(new BigDecimal(source),new BigDecimal("11"),BigDecimal.ZERO,BigDecimal.TEN));
                assertThat(failure).isInstanceOf(BusinessPrecisionRequiredException.class);
                assertThat(((BusinessPrecisionRequiredException)failure).details()).containsEntry("selectionRejected",true).containsEntry("notWritten",true);
            }
            assertThat(MoneyPolicy.bookValueSlice(new BigDecimal("0.6"),BigDecimal.TEN,BigDecimal.ZERO,new BigDecimal("9")))
                .as("an unused coarse choice must not change a finite result").isEqualByComparingTo("0.54");
        }
    }
    @Test @EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
    void installedSqlUsesTheSameFrozenProofAndTheSourceCatalogHasNoHiddenCoercion() throws Exception {
        try(var database=MigratedSchemaBaseline.openDatabase("inventory_exact_contract")){
            var db=new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()));
            for(var item:contract().path("cases")){
                String policy=item.path("precisionVersion").asInt()==1?null:JSON.writeValueAsString(Map.of("version",1,"choices",choices(item)));
                java.util.function.Supplier<BigDecimal> calculation=()->db.queryForObject(
                    "SELECT fn_inventory_value_interval(?,?,?,?,?,?::jsonb,false)",BigDecimal.class,
                    decimal(item,"value"),decimal(item,"from"),decimal(item,"to"),decimal(item,"denominator"),item.path("precisionVersion").asInt(),policy);
                if(item.has("required")){
                    Throwable failure=catchThrowable(calculation::get);
                    var requirement=BusinessPrecisionRequiredException.from(failure).orElseThrow(()->new AssertionError(item.path("id").asText(),failure));
                    assertThat(requirement.details()).containsEntry("reason",item.path("required").asText());
                }else assertThat(calculation.get()).as(item.path("id").asText()).isEqualByComparingTo(item.path("expected").asText());
            }
            assertThat(db.queryForObject("""
                SELECT count(*) FROM pg_attribute WHERE attrelid IN('stock_value_nodes'::regclass,'goods_bom_actual_usages'::regclass,'subcontract_material_issue_items'::regclass)
                AND atttypid='numeric'::regtype AND attnum>0 AND NOT attisdropped AND (atttypmod>=0 OR attgenerated<>'')
                """,Integer.class)).isZero();
        }
    }
}
