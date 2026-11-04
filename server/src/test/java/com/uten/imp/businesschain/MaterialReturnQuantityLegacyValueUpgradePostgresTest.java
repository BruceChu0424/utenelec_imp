package com.uten.imp.businesschain;

import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.subcontract.draw.SubcontractDrawCommandService;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.*;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnService;
import com.uten.imp.testsupport.TestFlyway;
import java.math.BigDecimal;
import java.nio.file.Files;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;

/** Real old issue/value facts precede the migration; only the new physical return adopts native quantities. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class MaterialReturnQuantityLegacyValueUpgradePostgresTest {
    @Test void aNewQuantityDoesNotInheritTheOldSourcesFourPlaceMonetaryProof()throws Exception {
        var stages=new LegacyValuationComponentUpgradePostgresTest();
        var logs=Files.createTempDirectory("uten-old-issue-new-return-");
        try(var postgres=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("old_issue_native_return")){
            postgres.start();
            TestFlyway.configure().dataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword()).locations("classpath:db/migration").target("1024").load().migrate();
            Facts facts;
            try(ConfigurableApplicationContext before=call(stages,"start",postgres,logs,"1024","before")){
                var fixture=new SubcontractStepDrawEndToEndTest();before.getAutowireCapableBeanFactory().autowireBean(fixture);fixture.setup();
                String tag="old-issue-quantity-"+UUID.randomUUID();var world=fixture.fixture.seedWorld(tag);fixture.fixture.loginAs(world.superAdminUserId());
                call(fixture,"grantAuthorities",world.superAdminUserId(),new String[]{"subcontract_order:view","subcontract_order:draw","subcontract:view:all"});
                UUID parent=call(fixture,"goods",world,tag,"P","委外"),material=call(fixture,"goods",world,tag,"M","采购");
                fixture.fixture.insertBom(parent,material,"1");call(fixture,"otherIn",world,world.warehouseId(),material,null,"10","10");
                UUID order=call(fixture,"subcontractOrder",world,parent,"10",BusinessTime.today().plusDays(5),null);call(fixture,"approveSubcontract",world,order);
                UUID orderItem=call(fixture,"itemOf",order);
                var issued=before.getBean(SubcontractDrawCommandService.class).submit(new DrawSubmitRequest(List.of(new DrawItemRequest(orderItem,null)),"old-native-return-"+orderItem));
                issued.issueIds().forEach(before.getBean(SubcontractMaterialIssueService.class)::approve);
                var db=before.getBean(JdbcTemplate.class);UUID issueItem=db.queryForObject("SELECT id FROM subcontract_material_issue_items WHERE issue_id=? AND NOT is_deleted",UUID.class,issued.issueIds().getFirst());
                facts=new Facts(world,parent,material,orderItem,issueItem,issued.issueIds().getFirst(),originalMovements(db,issued.issueIds().getFirst()));
            }
            TestFlyway.configure().dataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword()).locations("classpath:db/migration").load().migrate();
            try(ConfigurableApplicationContext after=call(stages,"start",postgres,logs,"latest","after")){
                var db=after.getBean(JdbcTemplate.class);var fixture=new SubcontractStepDrawEndToEndTest();after.getAutowireCapableBeanFactory().autowireBean(fixture);fixture.setup();
                fixture.fixture.loginAs(facts.world().superAdminUserId());
                assertThat(originalMovements(db,facts.issue())).isEqualTo(facts.originalMoves());
                assertThat(db.queryForObject("SELECT count(*) FROM stock_value_nodes WHERE owner_kind='SUBCONTRACT_WIP' AND owner_id=? AND value_precision_version=1",Integer.class,facts.issueItem())).isPositive();
                for(String qty:List.of("0.000123456","0.000000000000000000000001")){
                    UUID returned=call(fixture,"materialReturn",facts.world(),facts.world().warehouseId(),facts.orderItem(),facts.parent(),facts.material(),facts.issueItem(),qty);
                    BigDecimal expected=new BigDecimal(qty);
                    assertThat(db.queryForObject("SELECT quantity_adoption_version FROM subcontract_material_return_items WHERE material_return_id=?",Integer.class,returned)).isEqualTo(2);
                    assertThat(db.queryForObject("SELECT qty FROM stock_movements WHERE source_doc_type='SUBCONTRACT_MATERIAL_RETURN' AND source_doc_id=? AND direction=1",BigDecimal.class,returned)).isEqualByComparingTo(expected);
                    assertThat(db.queryForObject("SELECT qty_base FROM stock_value_events WHERE source_doc_type='SUBCONTRACT_MATERIAL_RETURN' AND source_doc_id=? AND operation='POSITION_STORE'",BigDecimal.class,returned)).isEqualByComparingTo(expected);
                    try(var unrelated=BusinessPrecisionContext.use(Map.of("quantity.to-base",new BusinessPrecisionContext.Choice(0,"HALF_UP")))){after.getBean(SubcontractMaterialReturnService.class).reverse(returned);}
                    assertThat(db.queryForObject("SELECT qty FROM stock_movements WHERE source_doc_type='SUBCONTRACT_MATERIAL_RETURN' AND source_doc_id=? AND direction=-1",BigDecimal.class,returned)).isEqualByComparingTo(expected);
                    assertThat(db.queryForObject("SELECT returned_qty FROM subcontract_material_issue_items WHERE id=?",BigDecimal.class,facts.issueItem())).isZero();
                    assertThat(originalMovements(db,facts.issue())).isEqualTo(facts.originalMoves());
                }
            }
        }
    }
    private static String originalMovements(JdbcTemplate db,UUID issue){return db.queryForObject("SELECT jsonb_agg(to_jsonb(movement) ORDER BY movement.id)::text FROM stock_movements movement WHERE source_doc_type='SUBCONTRACT_MATERIAL_ISSUE' AND source_doc_id=?",String.class,issue);}
    @SuppressWarnings("unchecked") private static <T>T call(Object owner,String method,Object...args){return (T)ReflectionTestUtils.invokeMethod(owner,method,args);}
    private record Facts(FullChainEndToEndTest.World world,UUID parent,UUID material,UUID orderItem,UUID issueItem,UUID issue,String originalMoves){}
}
