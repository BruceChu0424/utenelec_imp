package com.uten.imp.common.platformcolumns;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import java.math.BigDecimal;
import java.sql.Connection;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.Supplier;
import static com.uten.imp.common.platformcolumns.PlatformColumnContracts.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class PlatformColumnServicePostgresTest {
    private static PostgreSQLContainer<?> postgres;
    private Connection connection;
    private JdbcTemplate sql;
    private TransactionTemplate transaction;
    private PlatformColumnService service;
    private UUID actor;
    private final UUID record=UUID.randomUUID();
    private TestAdapter master,document,report;
    private SecurityContextCurrentUser currentUser;
    private DataSourceTransactionManager manager;
    @BeforeAll static void migrate(){postgres=MigratedSchemaBaseline.startMigratedContainer("platform_fields_template");}
    @AfterAll static void stop(){if(postgres!=null)postgres.stop();}
    @BeforeEach void setup() throws Exception {
        connection=MigratedSchemaBaseline.cloneConnection(postgres,"pf_"+UUID.randomUUID().toString().replace("-",""));
        var ds=new SingleConnectionDataSource(connection,true);
        sql=new JdbcTemplate(ds);manager=new DataSourceTransactionManager(ds);transaction=new TransactionTemplate(manager);
        actor=UUID.randomUUID();currentUser=mock(SecurityContextCurrentUser.class);when(currentUser.requireId()).thenAnswer(c->actor);
        master=new TestAdapter("goods",true,false);document=new TestAdapter("sales_order",false,false);report=new TestAdapter("stock_summary",false,true);
        service=new PlatformColumnService(List.of(master,document,report),new NamedParameterJdbcTemplate(ds),new ObjectMapper(),currentUser,mock(TxSessionVars.class));
    }
    @AfterEach void close() throws Exception {connection.close();}
    private <T>T tx(Supplier<T> work){return transaction.execute(status->work.get());}
    private Definition define(String scope,String name,String type,boolean price,Formula formula){return tx(()->service.create(scope,new CreateDefinition(name,type,price,formula)));}
    private Formula factFormula(String fact,String op,String constant){return new Formula(new Operand(null,fact,null),List.of(new Step(op,new Operand(null,null,constant))));}
    private Row read(String scope,UUID... columns){return service.read(scope,new BatchRead(List.of(record),List.of(columns))).getFirst();}

    @Test void authorizedRecordRoundTripCasAndAuditArePersistent() {
        var column=define("goods","包装说明","TEXT",false,null);
        Row saved=tx(()->service.write("goods",record,new Write(0,List.of(new CellInput(column.id(),"双层")))));
        assertThat(saved.version()).isEqualTo(1);assertThat(read("goods").cells().getFirst().value()).isEqualTo("双层");
        assertThatThrownBy(()->tx(()->service.write("goods",record,new Write(0,List.of())))).isInstanceOf(ApiException.class);
        assertThat(read("goods").cells().getFirst().value()).isEqualTo("双层");
        assertThat(sql.queryForObject("SELECT retain_on_reset FROM platform_record_fields WHERE scope='goods'",Boolean.class)).isTrue();
        assertThat(sql.queryForObject("SELECT count(*) FROM audit_log WHERE target_type='platform_record_field_versions' AND after->>'record_id'=?",Integer.class,record.toString())).isPositive();
        assertThat(service.search("goods","包装说").getFirst().personalUsageCount()).isEqualTo(1);
        assertThatThrownBy(()->sql.update("UPDATE platform_column_definitions SET name='改变历史' WHERE id=?",column.id())).isInstanceOf(Exception.class);
    }

    @Test void readonlyProjectionCalculatesWithoutCreatingRowsAndNeverChangesBusinessFacts() {
        var formula=define("goods","展示数量","CALCULATED",false,factFormula("qty","MULTIPLY","2"));
        master.writable=false;
        Row projection=read("goods",formula.id());
        assertThat(projection.version()).isZero();assertThat(projection.canWrite()).isFalse();
        assertThat(projection.cells().getFirst().value()).isEqualTo("6");assertThat(projection.cells().getFirst().persisted()).isFalse();
        assertThat(sql.queryForObject("SELECT count(*) FROM platform_record_fields",Integer.class)).isZero();
        assertThatThrownBy(()->tx(()->service.write("goods",record,new Write(0,List.of(new CellInput(formula.id(),null)))))).isInstanceOf(ApiException.class);
    }

    @Test void permissionsUnknownIdsAndCrossScopeDefinitionsFailClosed() {
        var column=define("goods","数值","NUMBER",false,null);
        assertThatThrownBy(()->tx(()->service.write("sales_order",record,new Write(0,List.of(new CellInput(column.id(),"3")))))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->service.read("goods",new BatchRead(List.of(UUID.randomUUID()),null))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->service.read("goods;delete",new BatchRead(List.of(record),null))).isInstanceOf(ApiException.class);
        master.canDefine=false;
        assertThatThrownBy(()->define("goods","无授权","TEXT",false,null)).isInstanceOf(ApiException.class);
        assertThat(sql.queryForObject("SELECT count(*) FROM platform_record_fields",Integer.class)).isZero();
    }

    @Test void transitivePriceProtectionMasksValuesFormulaAndCatalogAndPreservesHiddenData() {
        var price=define("goods","进价","NUMBER",true,null);
        var computed=define("goods","折算","CALCULATED",false,new Formula(new Operand(price.id(),null,null),List.of(new Step("MULTIPLY",new Operand(null,null,"2")))));
        tx(()->service.write("goods",record,new Write(0,List.of(new CellInput(price.id(),"7"),new CellInput(computed.id(),null)))));
        master.priceVisible=false;
        assertThat(service.search("goods","")).isEmpty();
        Row masked=read("goods");
        assertThat(masked.cells()).allSatisfy(c->{assertThat(c.masked()).isTrue();assertThat(c.value()).isNull();assertThat(c.definition().formula()).isNull();});
        assertThatThrownBy(()->tx(()->service.write("goods",record,new Write(1,List.of())))).isInstanceOf(ApiException.class);
        tx(()->service.write("goods",record,new Write(1,List.of(new CellInput(price.id(),null),new CellInput(computed.id(),null)))));
        master.priceVisible=true;assertThat(read("goods").cells().getFirst().value()).isEqualTo("7");
    }

    @Test void reportDefinitionsArePerActorAndOnlyWhitelistedVisibleFactsAreAllowed() {
        var first=define("stock_summary","显示","CALCULATED",false,factFormula("qty","ADD","1"));
        var secondLevel=define("stock_summary","再次显示","CALCULATED",false,new Formula(new Operand(first.id(),null,null),List.of(new Step("MULTIPLY",new Operand(null,null,"2")))));
        assertThat(service.definitions("stock_summary",List.of(secondLevel.id()))).extracting(Definition::id).containsExactlyInAnyOrder(first.id(),secondLevel.id());
        assertThat(service.evaluateDisplayRows("stock_summary",List.of(secondLevel.id()),List.of(Map.of("qty",BigDecimal.ONE),Map.of("qty",BigDecimal.TEN))))
                .extracting(row->row.get(secondLevel.id())).containsExactly("4","22");
        assertThat(service.search("stock_summary","")).hasSize(2);
        actor=UUID.randomUUID();assertThat(service.search("stock_summary","")).isEmpty();
        var second=define("stock_summary","显示","CALCULATED",false,factFormula("qty","ADD","1"));
        assertThat(second.id()).isNotEqualTo(first.id());
        assertThatThrownBy(()->define("stock_summary","越界","CALCULATED",false,new Formula(new Operand(first.id(),null,null),List.of()))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->define("stock_summary","未知","CALCULATED",false,factFormula("arbitrary_sql","ADD","1"))).isInstanceOf(ApiException.class);
        report.priceVisible=false;
        assertThatThrownBy(()->define("stock_summary","敏感","CALCULATED",false,factFormula("price","ADD","1"))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->service.read("stock_summary",new BatchRead(List.of(record),null))).isInstanceOf(ApiException.class);
    }

    @Test void simultaneousFirstSaveHasOneWinnerAndOneVersionConflict() throws Exception {
        var column=define("goods","并发","TEXT",false,null);
        var ds=new DriverManagerDataSource(connection.getMetaData().getURL(),postgres.getUsername(),postgres.getPassword());
        var concurrent=new PlatformColumnService(List.of(master),new NamedParameterJdbcTemplate(ds),new ObjectMapper(),currentUser,mock(TxSessionVars.class));
        var tx=new TransactionTemplate(new DataSourceTransactionManager(ds));
        var start=new CountDownLatch(1);
        try(var pool=Executors.newFixedThreadPool(2)) {
            List<Future<Boolean>> tasks=new ArrayList<>();
            for(String value:List.of("A","B"))tasks.add(pool.submit(()->{
                start.await();try{tx.execute(s->concurrent.write("goods",record,new Write(0,List.of(new CellInput(column.id(),value)))));return true;}
                catch(ApiException conflict){assertThat(conflict.getCode()).isEqualTo(ErrorCode.CONFLICT);return false;}
            }));
            start.countDown();assertThat(List.of(tasks.get(0).get(15,TimeUnit.SECONDS),tasks.get(1).get(15,TimeUnit.SECONDS))).containsExactlyInAnyOrder(true,false);
        }
        assertThat(read("goods").version()).isEqualTo(1);
    }

    @Test void personalFormulasOverRealIdsCanReadAuthorizedFactsButCannotStoreBusinessValues() {
        report.projectionRecords=true;
        var column=define("stock_summary","个人显示","CALCULATED",false,factFormula("qty","ADD","2"));
        assertThat(read("stock_summary",column.id()).cells().getFirst().value()).isEqualTo("5");
        assertThatThrownBy(()->tx(()->service.write("stock_summary",record,new Write(0,List.of(new CellInput(column.id(),null))))))
                .isInstanceOf(ApiException.class).hasMessageContaining("个人计算展示");
        assertThat(sql.queryForObject("SELECT count(*) FROM platform_record_fields",Integer.class)).isZero();
    }

    @Test void displayAuthoritiesArePresentInTheActualPermissionCatalog() throws Exception {
        String source=java.nio.file.Files.readString(java.nio.file.Path.of("src/main/java/com/uten/imp/config/PlatformDisplayColumnsConfiguration.java"));
        var pattern=java.util.regex.Pattern.compile("\"([a-z][a-z_]*(?::[a-z][a-z_]*){1,2})\"");var matcher=pattern.matcher(source);
        Set<String> declared=new HashSet<>();while(matcher.find())declared.add(matcher.group(1));
        declared.removeAll(sql.queryForList("SELECT code FROM permissions",String.class));
        assertThat(declared).as("Display adapters must use real functional authorities").isEmpty();
    }

    @Test void explicitTestResetClearsCommercialHistoryButRetainsMasterCellsAndImmutableDefinitions() {
        var masterColumn=define("goods","保留主档","TEXT",false,null);
        var docColumn=define("sales_order","保留单据","TEXT",false,null);
        tx(()->service.write("goods",record,new Write(0,List.of(new CellInput(masterColumn.id(),"主档备注")))));
        tx(()->service.write("sales_order",record,new Write(0,List.of(new CellInput(docColumn.id(),"业务原备注")))));
        var masterBefore=sql.queryForList("SELECT scope,record_id,version,cells::text FROM platform_record_fields WHERE scope='goods'");
        assertThat(sql.queryForObject("SELECT count(*) FROM platform_record_field_versions",Integer.class)).isEqualTo(2);
        // Ordinary destruction remains forbidden; only the authenticated whole testing reset has an exception.
        assertThatThrownBy(()->sql.update("DELETE FROM platform_record_field_versions"))
            .isInstanceOf(org.springframework.dao.DataAccessException.class).hasMessageContaining("permanent");
        assertThatThrownBy(()->sql.update("UPDATE platform_column_definitions SET name='changed' WHERE id=?",masterColumn.id()))
            .isInstanceOf(org.springframework.dao.DataAccessException.class);
        transaction.execute(status->sql.queryForList("SELECT * FROM business_data_reset()"));
        assertThat(sql.queryForList("SELECT scope,record_id,version,cells::text FROM platform_record_fields WHERE scope='goods'")).isEqualTo(masterBefore);
        assertThat(sql.queryForObject("SELECT count(*) FROM platform_record_fields WHERE scope='sales_order'",Integer.class)).isZero();
        assertThat(sql.queryForObject("SELECT count(*) FROM platform_record_field_versions",Integer.class)).isZero();
        assertThat(sql.queryForObject("SELECT count(*) FROM platform_column_definitions",Integer.class)).isEqualTo(2);
        assertThat(sql.queryForObject("SELECT name FROM platform_column_definitions WHERE id=?",String.class,masterColumn.id())).isEqualTo("保留主档");
        assertThatThrownBy(()->sql.update("DELETE FROM platform_column_definitions WHERE id=?",masterColumn.id()))
            .isInstanceOf(org.springframework.dao.DataAccessException.class);
    }

    @Test void saveBridgeRekeysMaskedFieldsTogetherWithTheRealBusinessRow() {
        var column=define("goods","受保护备注","NUMBER",true,null);
        tx(()->service.write("goods",record,new Write(0,List.of(new CellInput(column.id(),"7")))));
        var documents=businessDocuments(false);master.priceVisible=false;
        var line=new SaveLine(record,1,BigDecimal.TEN);
        line.setPlatformFields(new PlatformColumnLineInput.Fields(record,1,List.of(new CellInput(column.id(),null))));
        SaveResult saved=documents.save(master.documentId,new SaveRequest(List.of(line)));
        UUID newId=saved.items().getFirst().id();
        assertThat(newId).isNotEqualTo(record);
        assertThat(sql.queryForObject("SELECT id FROM platform_test_document_rows",UUID.class)).isEqualTo(newId);
        assertThat(sql.queryForObject("SELECT cells->0->>'value' FROM platform_record_fields WHERE record_id=?",String.class,newId)).isEqualTo("7");
    }

    @Test void saveBridgeMappingFailureRollsBackBusinessRowsAndExtensions() {
        var column=define("goods","备注","TEXT",false,null);
        tx(()->service.write("goods",record,new Write(0,List.of(new CellInput(column.id(),"原值")))));
        var documents=businessDocuments(true);
        var line=new SaveLine(record,1,BigDecimal.TEN);
        line.setPlatformFields(new PlatformColumnLineInput.Fields(record,1,List.of(new CellInput(column.id(),"修改"))));
        assertThatThrownBy(()->documents.save(master.documentId,new SaveRequest(List.of(line)))).isInstanceOf(ApiException.class);
        assertThat(sql.queryForObject("SELECT id FROM platform_test_document_rows",UUID.class)).isEqualTo(record);
        assertThat(read("goods").cells().getFirst().value()).isEqualTo("原值");
        assertThat(sql.queryForObject("SELECT count(*) FROM platform_record_fields",Integer.class)).isEqualTo(1);
    }

    @Test void legalBusinessEditPreservesFrozenFieldsWithoutWritingOrAdvancingTheirVersion() {
        var column=define("goods","历史备注","TEXT",false,null);
        tx(()->service.write("goods",record,new Write(0,List.of(new CellInput(column.id(),"原值")))));
        var documents=businessDocuments(false);master.writable=false;
        var line=new SaveLine(record,1,new BigDecimal("11"));
        documents.saveSame(master.documentId,new SaveRequest(List.of(line)));
        line.setPlatformFields(new PlatformColumnLineInput.Fields(record,1,List.of(new CellInput(column.id(),"原值"))));
        documents.saveSame(master.documentId,new SaveRequest(List.of(line)));
        assertThat(sql.queryForObject("SELECT qty FROM platform_test_document_rows",BigDecimal.class)).isEqualByComparingTo("11");
        assertThat(read("goods").version()).isEqualTo(1);
        assertThat(read("goods").cells().getFirst().value()).isEqualTo("原值");
        assertThat(service.search("goods","").getFirst().personalUsageCount()).isEqualTo(1);
        assertThatThrownBy(()->tx(()->service.write("goods",record,new Write(1,List.of(new CellInput(column.id(),"原值"))))))
                .isInstanceOf(ApiException.class); // The public write endpoint is never exempted.
    }

    @Test void frozenFieldChangesAndStaleVersionsFailBeforeTheBusinessCanReopenTheDocument() {
        var column=define("goods","历史备注","TEXT",false,null);
        tx(()->service.write("goods",record,new Write(0,List.of(new CellInput(column.id(),"原值")))));
        var documents=businessDocuments(false);master.writable=false;
        for(var input:List.of(
                new PlatformColumnLineInput.Fields(record,1,List.of(new CellInput(column.id(),"篡改"))),
                new PlatformColumnLineInput.Fields(record,1,List.of()),
                new PlatformColumnLineInput.Fields(record,0,List.of(new CellInput(column.id(),"原值"))),
                new PlatformColumnLineInput.Fields(null,0,List.of(new CellInput(column.id(),"新增绕过"))),
                new PlatformColumnLineInput.Fields(null,0,List.of()))) {
            var line=new SaveLine(record,1,new BigDecimal("11"));line.setPlatformFields(input);
            assertThatThrownBy(()->documents.saveSame(master.documentId,new SaveRequest(List.of(line)))).isInstanceOf(ApiException.class);
            assertThat(sql.queryForObject("SELECT qty FROM platform_test_document_rows",BigDecimal.class)).isEqualByComparingTo("10");
            assertThat(read("goods").version()).isEqualTo(1);
            assertThat(read("goods").cells().getFirst().value()).isEqualTo("原值");
        }
        var line=new SaveLine(record,1,BigDecimal.TEN);
        assertThatThrownBy(()->documents.save(master.documentId,new SaveRequest(List.of(line)))).isInstanceOf(ApiException.class);
        assertThat(sql.queryForObject("SELECT id FROM platform_test_document_rows",UUID.class)).isEqualTo(record);
    }

    @Test void readSnapshotCannotPreserveARecordOutsideItsAuthorizedScope() {
        var documents=businessDocuments(false);master.allowed.remove(record);
        assertThatThrownBy(()->documents.saveSame(master.documentId,new SaveRequest(List.of(new SaveLine(record,1,BigDecimal.ONE)))))
                .isInstanceOf(ApiException.class).hasMessageContaining("不可见");
        assertThat(sql.queryForObject("SELECT qty FROM platform_test_document_rows",BigDecimal.class)).isEqualByComparingTo("10");
    }

    @Test void frozenMaskedRoundTripPreservesTheHiddenValueButCannotDeleteIt() {
        var column=define("goods","隐藏金额","NUMBER",true,null);
        tx(()->service.write("goods",record,new Write(0,List.of(new CellInput(column.id(),"7")))));
        var documents=businessDocuments(false);master.writable=false;master.priceVisible=false;
        var line=new SaveLine(record,1,BigDecimal.TEN);
        line.setPlatformFields(new PlatformColumnLineInput.Fields(record,1,List.of(new CellInput(column.id(),null))));
        documents.saveSame(master.documentId,new SaveRequest(List.of(line)));
        assertThat(sql.queryForObject("SELECT cells->0->>'value' FROM platform_record_fields WHERE record_id=?",String.class,record)).isEqualTo("7");
        assertThat(read("goods").version()).isEqualTo(1);
        assertThat(read("goods").cells().getFirst().masked()).isTrue();
        line.setPlatformFields(new PlatformColumnLineInput.Fields(record,1,List.of()));
        assertThatThrownBy(()->documents.saveSame(master.documentId,new SaveRequest(List.of(line)))).isInstanceOf(ApiException.class).hasMessageContaining("敏感字段");
    }

    @Test void unchangedFieldsCannotBeRekeyedOntoAnExistingSiblingRow() {
        var column=define("goods","原始来源","TEXT",false,null);
        tx(()->service.write("goods",record,new Write(0,List.of(new CellInput(column.id(),"来源值")))));
        var documents=businessDocuments(false);UUID sibling=UUID.randomUUID();
        master.allowed.add(sibling);master.parents.put(sibling,master.documentId);
        sql.update("INSERT INTO platform_test_document_rows VALUES(?,10)",sibling);
        var line=new SaveLine(record,1,BigDecimal.TEN);
        assertThatThrownBy(()->documents.saveExistingSibling(master.documentId,new SaveRequest(List.of(line))))
                .isInstanceOf(ApiException.class).hasMessageContaining("本次新建");
        assertThat(sql.queryForList("SELECT record_id FROM platform_record_fields",UUID.class)).containsExactly(record);
        assertThat(sql.queryForObject("SELECT count(*) FROM platform_test_document_rows",Integer.class)).isEqualTo(2);
    }

    @Test void documentBridgeStillRequiresFunctionalEditAuthorityWhenNoFieldsWereSubmitted() {
        var documents=businessDocuments(false);master.canDefine=false;
        assertThatThrownBy(()->documents.saveSame(master.documentId,new SaveRequest(List.of(new SaveLine(record,1,BigDecimal.ONE)))))
                .isInstanceOf(ApiException.class).hasMessageContaining("编辑权限");
        assertThat(sql.queryForObject("SELECT qty FROM platform_test_document_rows",BigDecimal.class)).isEqualByComparingTo("10");
    }

    @Test void legacySaveWithoutAStableSourceCannotSilentlyDropStoredFields() {
        var column=define("goods","备注","TEXT",false,null);
        tx(()->service.write("goods",record,new Write(0,List.of(new CellInput(column.id(),"原值")))));
        var documents=businessDocuments(false);
        assertThatThrownBy(()->documents.save(master.documentId,new SaveRequest(List.of(new SaveLine(null,1,BigDecimal.TEN)))))
                .isInstanceOf(ApiException.class).hasMessageContaining("刷新");
        assertThat(sql.queryForObject("SELECT id FROM platform_test_document_rows",UUID.class)).isEqualTo(record);
    }

    @Test void createOnlyBridgeNeedsNewPersistenceProofAndReplayCannotEditAnExistingRecord() {
        var column=define("goods","新建资料","TEXT",false,null);
        var documents=businessDocuments(false);sql.update("DELETE FROM platform_test_document_rows");
        master.writable=false;master.canDefine=false;
        var line=new SaveLine(null,1,BigDecimal.TEN);
        line.setPlatformFields(new PlatformColumnLineInput.Fields(null,0,List.of(new CellInput(column.id(),"首次"))));
        UUID target=documents.create(new SaveRequest(List.of(line))).items().getFirst().id();
        assertThat(sql.queryForObject("SELECT cells->0->>'value' FROM platform_record_fields WHERE record_id=?",String.class,target)).isEqualTo("首次");
        documents.create(new SaveRequest(List.of(line)));
        assertThat(sql.queryForObject("SELECT version FROM platform_record_fields WHERE record_id=?",Long.class,target)).isEqualTo(1);
        line.setPlatformFields(new PlatformColumnLineInput.Fields(null,0,List.of(new CellInput(column.id(),"重放篡改"))));
        assertThatThrownBy(()->documents.create(new SaveRequest(List.of(line)))).isInstanceOf(ApiException.class).hasMessageContaining("既有记录");
        assertThatThrownBy(()->tx(()->service.write("goods",target,new Write(1,List.of(new CellInput(column.id(),"编辑")))))).isInstanceOf(ApiException.class);
        assertThat(sql.queryForObject("SELECT cells->0->>'value' FROM platform_record_fields WHERE record_id=?",String.class,target)).isEqualTo("首次");
    }

    @Test void loadingAnEntityCannotMasqueradeAsNewPersistence() {
        var entity=new com.uten.imp.common.domain.BaseEntity(){};
        try(var context=PlatformColumnSaveLineage.begin(Set.of())) {
            org.springframework.test.util.ReflectionTestUtils.invokeMethod(entity,"markPersisted");
            assertThat(PlatformColumnSaveLineage.wasPersisted(entity.getId())).isFalse();
            org.springframework.test.util.ReflectionTestUtils.invokeMethod(entity,"markNewlyPersisted");
            assertThat(PlatformColumnSaveLineage.wasPersisted(entity.getId())).isTrue();
        }
    }

    @Test void domainCreateReplayUsesStoredParentOrdinalAndVersionWithoutRegisteringNewRows() {
        var column=define("goods","拆分资料","TEXT",false,null);
        var documents=businessDocuments(false);sql.update("DELETE FROM platform_test_document_rows");
        master.writable=false;master.canDefine=false;
        var line=new SaveLine(null,1,BigDecimal.TEN);line.setPlatformFields(new PlatformColumnLineInput.Fields(null,0,List.of(new CellInput(column.id(),"原始"))));
        var created=documents.createSplit(new SaveRequest(List.of(line)));
        assertThat(created.items()).hasSize(2);
        documents.createSplit(new SaveRequest(List.of(line)));
        assertThat(sql.queryForList("SELECT version FROM platform_record_fields",Long.class)).containsExactlyInAnyOrder(1L,1L);
        assertThat(sql.queryForList("SELECT source_document_id FROM platform_record_fields",UUID.class)).containsOnly(master.documentId);
        line.setPlatformFields(new PlatformColumnLineInput.Fields(null,0,List.of(new CellInput(column.id(),"篡改"))));
        assertThatThrownBy(()->documents.createSplit(new SaveRequest(List.of(line)))).isInstanceOf(ApiException.class);
        line.setPlatformFields(new PlatformColumnLineInput.Fields(null,0,List.of(new CellInput(column.id(),"原始"))));
        sql.update("UPDATE platform_record_fields SET source_fields_version=3");
        assertThatThrownBy(()->documents.createSplit(new SaveRequest(List.of(line)))).isInstanceOf(ApiException.class).hasMessageContaining("缺少");
        sql.update("UPDATE platform_record_fields SET source_fields_version=0");
        master.parents.put(created.items().getFirst().id(),UUID.randomUUID());
        assertThatThrownBy(()->documents.createSplit(new SaveRequest(List.of(line)))).isInstanceOf(ApiException.class).hasMessageContaining("真实单据");
    }

    @Test void declaredDomainSplitsPreserveExtensionsOnlyWhenQuantityIsConserved() throws Exception {
        var column=define("goods","分批要求","TEXT",false,null);
        tx(()->service.write("goods",record,new Write(0,List.of(new CellInput(column.id(),"同一来源")))));
        var documents=businessDocuments(false);
        var line=new SaveLine(record,1,BigDecimal.TEN);
        line.setPlatformFields(new PlatformColumnLineInput.Fields(record,1,List.of(new CellInput(column.id(),"同一来源"))));
        var result=documents.split(master.documentId,new SaveRequest(List.of(line)));
        assertThat(result.items()).hasSize(2);
        for(var saved:result.items())assertThat(sql.queryForObject("SELECT cells->0->>'value' FROM platform_record_fields WHERE record_id=?",String.class,saved.id())).isEqualTo("同一来源");
        var bound=new ObjectMapper().readValue("{\"platformSaveToken\":\""+UUID.randomUUID()+"\"}",com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine.class);
        assertThat(bound.getPlatformSaveToken()).isNull();
        sql.update("DELETE FROM platform_test_document_rows");sql.update("INSERT INTO platform_test_document_rows VALUES(?,10)",record);
        var factory=new org.springframework.aop.aspectj.annotation.AspectJProxyFactory(new BusinessDocuments(sql,master.allowed,master.parents,master.documentId,true));
        factory.addAspect(new PlatformColumnDocumentSaveAspect(service,manager));BusinessDocuments invalid=factory.getProxy();
        assertThatThrownBy(()->invalid.split(master.documentId,new SaveRequest(List.of(line)))).isInstanceOf(ApiException.class).hasMessageContaining("不守恒");
        assertThat(sql.queryForObject("SELECT id FROM platform_test_document_rows",UUID.class)).isEqualTo(record);
    }

    private BusinessDocuments businessDocuments(boolean changeQty) {
        sql.execute("CREATE TABLE platform_test_document_rows(id uuid PRIMARY KEY,qty numeric NOT NULL)");
        sql.update("INSERT INTO platform_test_document_rows VALUES(?,10)",record);
        var factory=new org.springframework.aop.aspectj.annotation.AspectJProxyFactory(new BusinessDocuments(sql,master.allowed,master.parents,master.documentId,changeQty));
        factory.addAspect(new PlatformColumnDocumentSaveAspect(service,manager));return factory.getProxy();
    }
    public record SaveRequest(List<SaveLine> items) { }
    public record SaveResult(UUID id,List<SavedLine> items) { }
    public record SavedLine(UUID id,Integer lineNo,BigDecimal qty) { }
    public static class SaveLine extends PlatformColumnLineInput {
        private final UUID id;private final Integer lineNo;private final BigDecimal qty;
        SaveLine(UUID id,Integer lineNo,BigDecimal qty){this.id=id;this.lineNo=lineNo;this.qty=qty;}
        public UUID getId(){return id;}public Integer getLineNo(){return lineNo;}public BigDecimal getQty(){return qty;}
    }
    public static class BusinessDocuments {
        private final JdbcTemplate sql;private final Set<UUID> allowed;private final Map<UUID,UUID> parents;private final UUID documentId;private final boolean changeQty;
        BusinessDocuments(JdbcTemplate sql,Set<UUID> allowed,Map<UUID,UUID> parents,UUID documentId,boolean changeQty){this.sql=sql;this.allowed=allowed;this.parents=parents;this.documentId=documentId;this.changeQty=changeQty;}
        @PlatformColumnDocumentSave(scope="goods",requestArgument=1,documentIdArgument=0)
        public SaveResult save(UUID document,SaveRequest request){
            sql.update("DELETE FROM platform_test_document_rows");UUID next=UUID.randomUUID();allowed.add(next);parents.put(next,documentId);
            BigDecimal qty=changeQty?BigDecimal.ONE:request.items().getFirst().getQty();
            sql.update("INSERT INTO platform_test_document_rows VALUES(?,?)",next,qty);
            PlatformColumnSaveLineage.recordPersisted(next); // Mirrors the actual JPA @PostPersist callback.
            return new SaveResult(documentId,List.of(new SavedLine(next,1,qty)));
        }
        @PlatformColumnDocumentSave(scope="goods",requestArgument=1,documentIdArgument=0)
        public SaveResult saveSame(UUID document,SaveRequest request){
            var line=request.items().getFirst();
            sql.update("UPDATE platform_test_document_rows SET qty=? WHERE id=?",line.getQty(),line.getId());
            return new SaveResult(documentId,List.of(new SavedLine(line.getId(),1,line.getQty())));
        }
        @PlatformColumnDocumentSave(scope="goods",requestArgument=1,documentIdArgument=0)
        public SaveResult saveExistingSibling(UUID document,SaveRequest request){
            var line=request.items().getFirst();
            UUID sibling=sql.queryForObject("SELECT id FROM platform_test_document_rows WHERE id<>?",UUID.class,line.getId());
            return new SaveResult(documentId,List.of(new SavedLine(sibling,1,line.getQty())));
        }
        @PlatformColumnDocumentSave(scope="goods")
        public SaveResult create(SaveRequest request) {
            List<UUID> existing=sql.queryForList("SELECT id FROM platform_test_document_rows",UUID.class);
            UUID target;
            if(existing.isEmpty()) {
                target=UUID.randomUUID();allowed.add(target);parents.put(target,documentId);sql.update("INSERT INTO platform_test_document_rows VALUES(?,?)",target,request.items().getFirst().getQty());
                PlatformColumnSaveLineage.recordPersisted(documentId);PlatformColumnSaveLineage.recordPersisted(target); // JDBC fixture mirrors the real JPA @PostPersist callback.
            } else target=existing.getFirst();
            return new SaveResult(documentId,List.of(new SavedLine(target,1,request.items().getFirst().getQty())));
        }
        @PlatformColumnDocumentSave(scope="goods",requestArgument=1,documentIdArgument=0,mapping=PlatformColumnDocumentSave.Mapping.DOMAIN_LINEAGE)
        public SaveResult split(UUID document,SaveRequest request) {
            sql.update("DELETE FROM platform_test_document_rows");List<SavedLine> output=new ArrayList<>();
            var original=request.items().getFirst();
            for(int index=0;index<2;index++) {
                BigDecimal qty=index==0?new BigDecimal("4"):new BigDecimal(changeQty?"7":"6");
                var derived=new SaveLine(null,index+1,qty);PlatformColumnSaveLineage.copyToken(original,derived);
                UUID next=UUID.randomUUID();allowed.add(next);parents.put(next,documentId);sql.update("INSERT INTO platform_test_document_rows VALUES(?,?)",next,qty);
                PlatformColumnSaveLineage.recordPersisted(next);
                PlatformColumnSaveLineage.registerSaved(derived,next);output.add(new SavedLine(next,index+1,qty));
            }
            return new SaveResult(documentId,output);
        }
        @PlatformColumnDocumentSave(scope="goods",mapping=PlatformColumnDocumentSave.Mapping.DOMAIN_LINEAGE)
        public SaveResult createSplit(SaveRequest request) {
            var existing=sql.query("SELECT id,qty FROM platform_test_document_rows ORDER BY qty",(rs,index)->new SavedLine(rs.getObject(1,UUID.class),index+1,rs.getBigDecimal(2)));
            if(!existing.isEmpty())return new SaveResult(documentId,existing);
            var saved=split(documentId,request);PlatformColumnSaveLineage.recordPersisted(documentId);
            saved.items().forEach(row->PlatformColumnSaveLineage.recordPersisted(row.id()));return saved;
        }
    }

    private final class TestAdapter implements PlatformColumnResourceAdapter {
        private final String scope;private final boolean preserve,personal;
        boolean writable=true,priceVisible=true,canDefine=true,projectionRecords=false;
        final UUID documentId=UUID.randomUUID();
        final Set<UUID> allowed=new HashSet<>(Set.of(record));
        final Map<UUID,UUID> parents=new HashMap<>(Map.of(record,documentId));
        TestAdapter(String scope,boolean preserve,boolean personal){this.scope=scope;this.preserve=preserve;this.personal=personal;}
        public String scope(){return scope;}public String label(){return scope;}
        public void requireDefinitionAccess(boolean write){if(write&&!canDefine)throw new ApiException(ErrorCode.FORBIDDEN,"没有编辑权限");}
        public boolean canWrite(){return writable&&!personal;}public boolean canViewPrice(){return priceVisible;}
        public boolean canCreate(){return !personal;}
        public void requireDocumentSaveAccess(boolean create){if(!create)requireDefinitionAccess(true);else if(personal)throw new ApiException(ErrorCode.FORBIDDEN);}
        public Map<UUID,RecordAccess> authorizeCreated(Set<UUID> ids){if(ids.stream().anyMatch(id->!PlatformColumnSaveLineage.wasPersisted(id)))throw new ApiException(ErrorCode.CONFLICT);return authorize(ids,false);}
        public boolean supportsValues(){return !personal||projectionRecords;}public boolean personalDefinitions(){return personal;}public boolean preserveValuesOnReset(){return preserve;}
        public List<FactDefinition> facts(){return List.of(new FactDefinition("qty","数量",false),new FactDefinition("price","单价",true));}
        public Set<UUID> recordIdsForDocument(UUID id){if(!documentId.equals(id))throw new ApiException(ErrorCode.NOT_FOUND);authorize(Set.of(record),false);return Set.of(record);}
        public void requireDocumentFieldWrite(UUID id){recordIdsForDocument(id);requireDocumentSaveAccess(false);if(!writable)throw new ApiException(ErrorCode.CONFLICT,"当前单据不允许修改扩展字段");}
        public Map<UUID,UUID> parentDocuments(Set<UUID> ids){Map<UUID,UUID> result=new HashMap<>();ids.forEach(id->result.put(id,parents.get(id)));return result;}
        public Map<UUID,RecordAccess> authorize(Set<UUID> ids,boolean write){
            if(!allowed.containsAll(ids))throw new ApiException(ErrorCode.FORBIDDEN,"记录不可见");
            Map<UUID,RecordAccess> access=new HashMap<>();ids.forEach(id->access.put(id,new RecordAccess(canWrite(),priceVisible,Map.of("qty",new BigDecimal("3"),"price",new BigDecimal("7")))));return access;
        }
    }
}
