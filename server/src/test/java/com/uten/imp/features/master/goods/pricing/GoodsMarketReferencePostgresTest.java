package com.uten.imp.features.master.goods.pricing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.config.props.MaterialForecastProperties;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.*;
import org.springframework.transaction.support.TransactionTemplate;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.Supplier;
import static org.assertj.core.api.Assertions.*;

/** Uses the fully migrated real PostgreSQL schema, its audit triggers and concurrent CAS. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class GoodsMarketReferencePostgresTest {
    MigratedSchemaBaseline.ScopedDatabase database;JdbcTemplate db;TransactionTemplate tx;GoodsMarketReferenceStore store;
    UUID goods,actor;
    @TempDir Path snapshots;
    @BeforeEach void open()throws Exception{
        database=MigratedSchemaBaseline.openDatabase("goods_market_reference");var source=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());db=new JdbcTemplate(source);tx=new TransactionTemplate(new DataSourceTransactionManager(source));store=new GoodsMarketReferenceStore(new NamedParameterJdbcTemplate(source));goods=UUID.randomUUID();actor=UUID.randomUUID();
        UUID employee=UUID.randomUUID();
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,'market test','其他',id,current_date,'active','regular' FROM departments WHERE code='DEPT_FIN'",employee,"MARKET-"+employee);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) VALUES(?,?,?,'test-only','active',false)",actor,employee,"market-"+actor);
        run(()->{db.update("INSERT INTO goods(id,code,name,code_sequence) VALUES(?,?,'market test',(SELECT coalesce(max(code_sequence),0)+1 FROM goods))",goods,"MARKET-"+goods);return null;});
    }
    @AfterEach void close()throws Exception{if(database!=null)database.close();}
    <T>T run(Supplier<T> action){return tx.execute(status->{db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,actor.toString());return action.get();});}
    @Test void linkUnlinkAndRelinkKeepMonotonicTombstoneVersions(){
        assertThat(store.find(goods).version()).isZero();run(()->{store.compareAndSet(goods,"copper","a".repeat(64),0,actor);return null;});
        run(()->{store.compareAndSet(goods,null,null,1,actor);return null;});assertThat(store.find(goods).seriesId()).isNull();assertThat(store.find(goods).version()).isEqualTo(2);
        assertThatThrownBy(()->run(()->{store.compareAndSet(goods,"copper","a".repeat(64),0,actor);return null;})).hasMessageContaining("刷新");
        run(()->{store.compareAndSet(goods,"silver","b".repeat(64),2,actor);return null;});assertThat(store.find(goods).version()).isEqualTo(3);
        assertThat(db.queryForObject("SELECT count(*) FROM audit_log WHERE target_type='goods_market_reference_bindings'",Long.class)).isGreaterThanOrEqualTo(3);
    }
    @Test void databaseRejectsOneSidedIdentityAndDeletionOfTombstones(){
        assertThatThrownBy(()->run(()->{store.compareAndSet(goods,"copper",null,0,actor);return null;})).isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        assertThatThrownBy(()->run(()->{store.compareAndSet(goods,null,"a".repeat(64),0,actor);return null;})).isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        run(()->{store.compareAndSet(goods,null,null,0,actor);return null;});
        assertThatThrownBy(()->run(()->{db.update("DELETE FROM goods_market_reference_bindings WHERE goods_id=?",goods);return null;})).isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
    }
    @Test void twoConcurrentFirstWritersCannotBothWin()throws Exception{
        var start=new CountDownLatch(1);var pool=Executors.newFixedThreadPool(2);
        try{
            List<Future<Boolean>> writes=new ArrayList<>();
            for(String series:List.of("copper","silver")) {
                writes.add(pool.submit(()->{
                    start.await();
                    try {
                        run(()->{store.compareAndSet(goods,series,"a".repeat(64),0,actor);return null;});
                        return true;
                    } catch(com.uten.imp.common.web.ApiException conflict) {
                        return false;
                    }
                }));
            }
            start.countDown();
            int successes=0;
            for(var write:writes) {
                if(write.get(30,TimeUnit.SECONDS)) {
                    successes++;
                }
            }
            assertThat(successes).isEqualTo(1);
            assertThat(store.find(goods).version()).isEqualTo(1);
        }finally{pool.shutdownNow();}
    }

    @Test void unavailableDatePairsNeverEnterTheCatalogOrChangeAnExistingBinding() throws Exception {
        ObjectMapper json = new ObjectMapper();
        ObjectNode valid = insufficientSnapshot(json);
        String series = valid.path("seriesId").asText();
        Path file = snapshots.resolve(series + ".json");
        MaterialForecastSnapshotReader reader = reader(json, valid);
        Files.writeString(file, json.writeValueAsString(valid));
        MaterialForecastContracts.Snapshot snapshot = reader.read(series).snapshot();
        assertThat(snapshot).isNotNull();
        run(() -> {
            store.compareAndSet(goods, series, reader.identityDigest(snapshot), 0, actor);
            return null;
        });
        var binding = store.find(goods);
        Long auditRows = db.queryForObject("SELECT count(*) FROM audit_log", Long.class);

        for (String endpoint : List.of("backtestStart", "backtestEnd")) {
            for (boolean missingField : List.of(false, true)) {
                ObjectNode malformed = valid.deepCopy();
                ObjectNode validation = (ObjectNode) malformed.get("validation");
                if (missingField) {
                    validation.remove(endpoint);
                } else {
                    validation.putNull(endpoint);
                }
                Files.writeString(file, json.writeValueAsString(malformed));
                var result = reader.read(series);
                assertThat(result.status()).as("%s missing=%s", endpoint, missingField).isEqualTo("UNAVAILABLE");
                assertThat(result.snapshot()).isNull();
                assertThat(result.reasons()).containsExactly("MARKET_SNAPSHOT_UNAVAILABLE");
                assertThat(reader.catalog()).isEmpty();
                assertThat(store.find(goods)).isEqualTo(binding);
                assertThat(db.queryForObject("SELECT count(*) FROM audit_log", Long.class)).isEqualTo(auditRows);
            }
        }

        ObjectNode noBacktest = valid.deepCopy();
        ObjectNode validation = (ObjectNode) noBacktest.get("validation");
        validation.putNull("backtestStart");
        validation.putNull("backtestEnd");
        Files.writeString(file, json.writeValueAsString(noBacktest));
        assertThat(reader.read(series).status()).isEqualTo("INSUFFICIENT");
        assertThat(reader.catalog()).hasSize(1);
        assertThat(store.find(goods)).isEqualTo(binding);
    }

    @Test void backtestDatesMustBeOrderedAndCannotExtendPastTheDataDate() throws Exception {
        ObjectMapper json = new ObjectMapper();
        ObjectNode valid = insufficientSnapshot(json);
        MaterialForecastSnapshotReader reader = reader(json, valid);
        LocalDate asOf = LocalDate.parse(valid.path("dataAsOf").asText());
        String series = valid.path("seriesId").asText();
        for (List<LocalDate> dates : List.of(
                List.of(asOf, asOf.minusDays(1)),
                List.of(asOf.minusDays(1), asOf.plusDays(1)))) {
            ObjectNode malformed = valid.deepCopy();
            ObjectNode validation = (ObjectNode) malformed.get("validation");
            validation.put("backtestStart", dates.get(0).toString());
            validation.put("backtestEnd", dates.get(1).toString());
            Files.writeString(snapshots.resolve(series + ".json"), json.writeValueAsString(malformed));
            assertThat(reader.read(series).status()).as("%s", dates).isEqualTo("UNAVAILABLE");
            assertThat(reader.catalog()).isEmpty();
        }
    }

    private ObjectNode insufficientSnapshot(ObjectMapper json) throws Exception {
        ObjectNode snapshot;
        try (var source = getClass().getResourceAsStream("/pricing/material-forecast-worker-v1.synthetic.json")) {
            snapshot = (ObjectNode) json.readTree(source);
        }
        snapshot.remove("synthetic");
        snapshot.put("status", "INSUFFICIENT");
        snapshot.put("procurementSignal", "INSUFFICIENT");
        snapshot.putArray("forecasts");
        ((ObjectNode) snapshot.get("validation")).put("passed", false);
        return snapshot;
    }

    private MaterialForecastSnapshotReader reader(ObjectMapper json, ObjectNode fixture) {
        var properties = new MaterialForecastProperties();
        properties.setSnapshotDirectory(snapshots.toString());
        Clock clock = Clock.fixed(Instant.parse(fixture.path("generatedAt").asText()).plusSeconds(60), ZoneOffset.UTC);
        return new MaterialForecastSnapshotReader(properties, json, clock);
    }
}
