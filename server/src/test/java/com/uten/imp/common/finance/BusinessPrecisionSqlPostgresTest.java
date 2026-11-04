package com.uten.imp.common.finance;

import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.*;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.math.BigDecimal;
import java.util.List;
import static org.assertj.core.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class BusinessPrecisionSqlPostgresTest {
 static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");static JdbcTemplate db;static TransactionTemplate tx;
 @BeforeAll static void start(){PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());db=new JdbcTemplate(source);tx=new TransactionTemplate(new DataSourceTransactionManager(source));MigratedProjectionSchema.createCurrentFunctions(db,"fn_business_decimal_from_integer","fn_business_exact_divide_with_policy","fn_business_exact_divide","fn_business_precision_limit","fn_financial_book_part_legacy_proof_v1","fn_financial_book_part_proof");db.execute("CREATE TABLE precision_transaction_probe(id int PRIMARY KEY)");}
 @AfterAll static void stop(){PG.stop();}
 @Test void finiteDivisionPreservesMoreThanPostgresDefaultDivisionDigits(){
  assertThat(divide("1","1048576")).isEqualByComparingTo("0.00000095367431640625");assertThat(divide("-125","1000")).isEqualByComparingTo("-0.125");
  assertThat(divide("123456789012345678901234567890.123456789012345678901234","1")).isEqualByComparingTo("123456789012345678901234567890.123456789012345678901234");
 }
 @Test void nonFiniteDatabaseNumericsAreRejectedBeforeDivisionEvenForZeroOperands(){
  for(String invalid:List.of("NaN","Infinity","-Infinity")){
   assertThatThrownBy(()->divide(invalid,"1")).hasMessageContaining("must be finite");
   assertThatThrownBy(()->divide("0",invalid)).hasMessageContaining("must be finite");
   assertThatThrownBy(()->divide(invalid,"0")).hasMessageContaining("must be finite");
  }
 }
 @Test void omittedChoiceFailsAtomicallyAndSelectedModesAreTransactionLocal(){
  assertThatThrownBy(()->tx.execute(status->{db.update("INSERT INTO precision_transaction_probe VALUES(1)");return divide("2","3");})).hasMessageContaining("UTEN_PRECISION_REQUIRED");
  assertThat(db.queryForObject("SELECT count(*) FROM precision_transaction_probe",Integer.class)).isZero();
  assertThat(selected("2","3",2,"HALF_UP")).isEqualByComparingTo("0.67");assertThat(selected("-2","3",2,"DOWN")).isEqualByComparingTo("-0.66");
  assertThatThrownBy(()->divide("2","3")).hasMessageContaining("UTEN_PRECISION_REQUIRED");
 }
 @Test void finiteStorageProjectionAlsoRequiresExplicitDecision(){
  assertThatThrownBy(()->db.queryForObject("SELECT fn_business_exact_divide(1.005,1,'ratio','本次字段',2)",BigDecimal.class)).hasMessageContaining("PRECISION_LIMIT");
  BigDecimal selected=tx.execute(status->{set(2,"HALF_UP");return db.queryForObject("SELECT fn_business_exact_divide(1.005,1,'ratio','本次字段',2)",BigDecimal.class);});assertThat(selected).isEqualByComparingTo("1.01");
 }
 @Test void historicalProofAndNewFrozenChoiceAreIndependentOfTheCurrentRequest(){
  assertThat(db.queryForObject("SELECT fn_financial_book_part_proof(1,3,2,NULL)",BigDecimal.class))
      .isEqualByComparingTo("0.666666666666666666666666666666");
  String frozen="{\"version\":1,\"choices\":{\"money.book-share\":{\"scale\":2,\"rounding\":\"HALF_UP\"}}}";
  BigDecimal projected=tx.execute(status->{set(0,"DOWN");return db.queryForObject("SELECT fn_financial_book_part_proof(1,3,2,?::jsonb)",BigDecimal.class,frozen);});
  assertThat(projected).isEqualByComparingTo("0.67");
  assertThatThrownBy(()->db.queryForObject("SELECT fn_financial_book_part_proof(1,3,2,'{\"version\":1,\"choices\":{}}'::jsonb)",BigDecimal.class))
      .hasMessageContaining("UTEN_PRECISION_REQUIRED");
  assertThat(db.queryForObject("SELECT fn_financial_book_part_proof(3,3,2,'{\"version\":1,\"choices\":{}}'::jsonb)",BigDecimal.class))
      .isEqualByComparingTo("2");
 }
 @Test void sqlMatchesTheSameCrossLanguageCases(){
  for(var row:com.uten.imp.testsupport.BusinessPrecisionContractCases.load()){
   String n=row.path("numerator").asText(),d=row.path("denominator").asText();int max=row.path("maxScale").asInt();
   if(row.has("required"))assertThatThrownBy(()->db.queryForObject("SELECT fn_business_exact_divide(?::numeric,?::numeric,'ratio','本次比率',?)",BigDecimal.class,n,d,max))
       .as(row.path("id").asText()).hasMessageContaining(row.path("required").asText());
   else {
    BigDecimal result=tx.execute(status->{
     if(row.has("choice"))set(row.path("choice").path("scale").asInt(),row.path("choice").path("rounding").asText());
     return db.queryForObject("SELECT fn_business_exact_divide(?::numeric,?::numeric,'ratio','本次比率',?)",BigDecimal.class,n,d,max);
    });
    assertThat(result).as(row.path("id").asText()).isEqualByComparingTo(row.path("expected").asText());
   }
  }
 }
 BigDecimal divide(String n,String d){return db.queryForObject("SELECT fn_business_exact_divide(?::numeric,?::numeric,'ratio','本次比例',30)",BigDecimal.class,n,d);}
 BigDecimal selected(String n,String d,int scale,String mode){return tx.execute(status->{set(scale,mode);return divide(n,d);});}
 void set(int scale,String mode){db.queryForObject("SELECT set_config('app.business_precision_choices',?,true)",String.class,"{\"version\":1,\"choices\":{\"ratio\":{\"scale\":"+scale+",\"rounding\":\""+mode+"\"}}}");}
}
