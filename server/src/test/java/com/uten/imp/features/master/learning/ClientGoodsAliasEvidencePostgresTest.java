package com.uten.imp.features.master.learning;

import com.uten.imp.application.port.MasterIntakeLookupPort.AliasKind;
import com.uten.imp.application.port.MasterIntakeLookupPort.AliasScope;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.MigrationVersion;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.*;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import java.sql.Connection;
import java.util.*;
import java.util.concurrent.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Executes the production ledger SQL on a real, fully migrated PostgreSQL schema. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ClientGoodsAliasEvidencePostgresTest {
    private static PostgreSQLContainer<?> postgres;
    private static UUID legacyClient,legacyGoods,legacyDoc;
    private Connection connection;
    private JdbcTemplate sql;
    private TransactionTemplate transaction;
    private ClientGoodsAliasLedger ledger;
    private UUID client,goods,otherGoods,actor;

    @BeforeAll static void migrateLegacyThenForward() {
        postgres=new PostgreSQLContainer<>("postgres:16-alpine").withDatabaseName("alias_evidence_template");postgres.start();
        Flyway.configure().dataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword())
                .locations("classpath:db/migration").target(MigrationVersion.fromVersion("751")).load().migrate();
        JdbcTemplate sql=new JdbcTemplate(new DriverManagerDataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword()));
        legacyClient=seed(sql,"clients","client_categories");legacyGoods=seed(sql,"goods","material_categories");legacyDoc=UUID.randomUUID();
        sql.update("""
                INSERT INTO client_goods_aliases(client_id,alias_kind,alias_text,alias_norm,context_norm,goods_id,
                    confirm_count,explicit_count,first_confirmed_at,last_confirmed_at,last_source_doc_type,last_source_doc_id)
                VALUES(?,'PART_NO','LEGACY','LEGACY','',?,3,1,now(),now(),'quote',?)
                """,legacyClient,legacyGoods,legacyDoc);
        Flyway.configure().dataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword()).locations("classpath:db/migration").load().migrate();
    }
    @AfterAll static void stop(){if(postgres!=null)postgres.stop();}
    @BeforeEach void setup() throws Exception {
        connection=MigratedSchemaBaseline.cloneConnection(postgres,"alias_"+UUID.randomUUID().toString().replace("-",""));
        var dataSource=new SingleConnectionDataSource(connection,true);sql=new JdbcTemplate(dataSource);
        transaction=new TransactionTemplate(new DataSourceTransactionManager(dataSource));ledger=ledger(new NamedParameterJdbcTemplate(dataSource));
        client=seed(sql,"clients","client_categories");goods=seed(sql,"goods","material_categories");otherGoods=seed(sql,"goods","material_categories");actor=UUID.randomUUID();
    }
    @AfterEach void close() throws Exception {connection.close();}

    @Test void alternatingDocumentsAndReplayingTheFirstNeverInflatesConfirmation() {
        UUID a=UUID.randomUUID(),b=UUID.randomUUID();
        reconcile(a,List.of(alias(client,goods,"MODEL",false)));
        reconcile(b,List.of(alias(client,goods,"MODEL",false)));
        reconcile(a,List.of(alias(client,goods,"MODEL",true)));
        assertThat(count(client,goods,"MODEL","confirm_count")).isEqualTo(2);
        assertThat(count(client,goods,"MODEL","explicit_count")).isEqualTo(1);
        reconcile(a,List.of());
        assertThat(count(client,goods,"MODEL","confirm_count")).isEqualTo(1);
        assertThat(count(client,goods,"MODEL","explicit_count")).isZero();
        assertThat(sql.queryForObject("SELECT last_source_doc_id FROM client_goods_aliases WHERE client_id=? AND alias_norm='MODEL'",UUID.class,client)).isEqualTo(b);
        assertThat(ledger.hasActiveEvidence("quote",a)).isFalse();
        assertThat(sql.queryForObject("SELECT count(*) FROM sales_alias_document_evidence WHERE doc_id=? AND NOT active",Integer.class,a)).isEqualTo(1);
    }

    @Test void correctionAndRenamingRetractOnlyTheActualSourceDocument() {
        UUID a=UUID.randomUUID(),b=UUID.randomUUID();
        reconcile(a,List.of(alias(client,goods,"OLD",true)));reconcile(b,List.of(alias(client,goods,"OLD",true)));
        reconcile(a,List.of(alias(client,otherGoods,"NEW",true)));
        assertThat(count(client,goods,"OLD","confirm_count")).isEqualTo(1);
        assertThat(count(client,otherGoods,"NEW","confirm_count")).isEqualTo(1);
        reconcile(a,List.of());
        assertThat(count(client,otherGoods,"NEW","confirm_count")).isNull();
        assertThat(count(client,goods,"OLD","confirm_count")).isEqualTo(1);
    }

    @Test void noNewSignalRetainsOnlyAnExistingMatchingSourceWithoutTeachingOrCountingAgain() {
        UUID document=UUID.randomUUID();reconcile(document,List.of(alias(client,goods,"KEPT",true)));
        transaction.executeWithoutResult(status->{
            var result=ledger.retractChangedMappings("quote",document,List.of(),List.of(new SalesLearningPlanner.RetainedAlias(client,AliasKind.PART_NO,"KEPT",goods)));
            assertThat(result.changed()).isZero();
        });
        assertThat(count(client,goods,"KEPT","confirm_count")).isEqualTo(1);
        reconcile(document,List.of());assertThat(count(client,goods,"KEPT","confirm_count")).isNull();
    }

    @Test void globalConfidenceCountsClientsAndManualDeletionWithdrawsItsEvidence() {
        UUID a=UUID.randomUUID(),b=UUID.randomUUID(),c=UUID.randomUUID();UUID secondClient=seed(sql,"clients","client_categories");
        reconcile(a,List.of(alias(client,goods,"GLOBAL",true),alias(null,goods,"GLOBAL",true)));
        reconcile(b,List.of(alias(client,goods,"GLOBAL",true),alias(null,goods,"GLOBAL",true)));
        assertThat(count(null,goods,"GLOBAL","confirm_count")).isEqualTo(1);
        reconcile(c,List.of(alias(secondClient,goods,"GLOBAL",true),alias(null,goods,"GLOBAL",true)));
        assertThat(count(null,goods,"GLOBAL","confirm_count")).isEqualTo(2);
        reconcile(a,List.of());assertThat(count(null,goods,"GLOBAL","confirm_count")).isEqualTo(2);
        reconcile(b,List.of());assertThat(count(null,goods,"GLOBAL","confirm_count")).isEqualTo(1);
        transaction.executeWithoutResult(status->{
            sql.update("DELETE FROM client_goods_aliases WHERE client_id=? AND alias_norm='GLOBAL'",secondClient);
            ledger.refreshGlobalConfidence(List.of(new ClientGoodsAliasLedger.EvidenceKey(AliasKind.PART_NO,"GLOBAL",goods)),List.of());
        });
        assertThat(sql.queryForObject("SELECT count(*) FROM sales_alias_document_evidence WHERE client_id=? AND active",Integer.class,secondClient)).isZero();
        assertThat(count(null,goods,"GLOBAL","explicit_count")).isZero();
    }

    @Test void legacyMigrationKeepsUnattributedFactsWithoutFabricatedOrAdditiveCounts() {
        assertThat(sql.queryForObject("SELECT count(*) FROM sales_alias_document_evidence WHERE alias_norm='LEGACY'",Integer.class)).isZero();
        assertThat(count(legacyClient,legacyGoods,"LEGACY","legacy_confirm_count")).isEqualTo(3);
        reconcile(legacyDoc,List.of(alias(legacyClient,legacyGoods,"LEGACY",true)));
        assertThat(count(legacyClient,legacyGoods,"LEGACY","confirm_count")).isEqualTo(3);
        reconcile(legacyDoc,List.of());
        assertThat(count(legacyClient,legacyGoods,"LEGACY","confirm_count")).isEqualTo(3);
        assertThat(sql.queryForObject("SELECT legacy_source_doc_id FROM client_goods_aliases WHERE alias_norm='LEGACY'",UUID.class)).isEqualTo(legacyDoc);
        assertThatThrownBy(()->sql.update("UPDATE sales_alias_document_evidence SET doc_id=? WHERE doc_id=?",UUID.randomUUID(),legacyDoc)).hasMessageContaining("immutable");
    }

    @Test void concurrentIndependentDocumentsProduceAnExactDistinctDocumentCount() throws Exception {
        var dataSource=new DriverManagerDataSource(connection.getMetaData().getURL(),postgres.getUsername(),postgres.getPassword());
        var parallel=ledger(new NamedParameterJdbcTemplate(dataSource));var transactions=new TransactionTemplate(new DataSourceTransactionManager(dataSource));
        List<UUID> docs=java.util.stream.IntStream.range(0,8).mapToObj(i->UUID.randomUUID()).toList();
        try(var pool=Executors.newFixedThreadPool(4)) {
            List<Future<?>> work=new ArrayList<>();
            for(UUID id:docs)work.add(pool.submit(()->transactions.executeWithoutResult(status->apply(parallel,id,List.of(alias(client,goods,"RACE",false))))));
            for(var task:work)task.get(20,TimeUnit.SECONDS);
        }
        reconcile(docs.getFirst(),List.of(alias(client,goods,"RACE",false)));
        assertThat(count(client,goods,"RACE","confirm_count")).isEqualTo(8);
    }

    private void reconcile(UUID doc,List<SalesLearningPlanner.AliasUpsert> aliases){transaction.executeWithoutResult(s->apply(ledger,doc,aliases));}
    private void apply(ClientGoodsAliasLedger target,UUID doc,List<SalesLearningPlanner.AliasUpsert> aliases){
        var retracted=target.retractChangedMappings("quote",doc,aliases);var keys=new HashSet<>(retracted.touched());
        keys.addAll(target.supersedeAutoLearned(aliases));target.upsert("quote",doc,actor,aliases);
        aliases.forEach(a->keys.add(new ClientGoodsAliasLedger.EvidenceKey(a.kind(),a.norm(),a.goodsId())));target.refreshGlobalConfidence(keys,retracted.releasedGlobalIds());
    }
    private SalesLearningPlanner.AliasUpsert alias(UUID client,UUID goods,String name,boolean explicit){return new SalesLearningPlanner.AliasUpsert(client==null?AliasScope.GLOBAL:AliasScope.CLIENT,client,AliasKind.PART_NO,name,name,"",goods,explicit);}
    private Integer count(UUID client,UUID goods,String norm,String field){
        var rows=sql.queryForList("SELECT "+field+" FROM client_goods_aliases WHERE client_id IS NOT DISTINCT FROM ? AND goods_id=? AND alias_norm=?",Integer.class,client,goods,norm);
        return rows.isEmpty()?null:rows.getFirst();
    }
    private static UUID seed(JdbcTemplate sql,String table,String categories){
        UUID id=UUID.randomUUID();String code="ALE-"+id;
        int rows=sql.update("INSERT INTO "+table+"(id,code,name,status,category_id,code_sequence,code_managed) "
                +"SELECT ?,?,?,'使用',category.id,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM "+table+"),false FROM "+categories+" category ORDER BY category.id LIMIT 1",id,code,code);
        assertThat(rows).isEqualTo(1);return id;
    }
    private static ClientGoodsAliasLedger ledger(NamedParameterJdbcTemplate jdbc){
        EntityManager em=mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call->{
            String sql=call.getArgument(0);Map<String,Object> parameters=new HashMap<>();Query query=mock(Query.class);
            when(query.setParameter(anyString(),any())).thenAnswer(p->{parameters.put(p.getArgument(0),p.getArgument(1));return query;});
            java.util.function.Supplier<List<Object>> rows=()->jdbc.query(sql,parameters,(rs,n)->{
                int columns=rs.getMetaData().getColumnCount();if(columns==1)return rs.getObject(1);
                Object[] values=new Object[columns];for(int i=0;i<columns;i++)values[i]=rs.getObject(i+1);return values;
            });
            when(query.getResultList()).thenAnswer(q->rows.get());when(query.getSingleResult()).thenAnswer(q->rows.get().getFirst());
            when(query.executeUpdate()).thenAnswer(q->jdbc.update(sql,parameters));return query;
        });return new ClientGoodsAliasLedger(em);
    }
}
