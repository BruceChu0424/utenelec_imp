package com.uten.imp.common.domain;

import com.uten.testprobe.persistable.PersistableProbe;
import com.uten.testprobe.persistable.PersistableProbeRepository;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DelegatingDataSource;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.lang.reflect.Proxy;
import java.sql.Connection;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.Properties;

import static org.junit.jupiter.api.Assertions.*;

/**
 * BaseEntity 实现 Persistable(ADR-107 / perf-warehouse-quality-14): 新建实体 save 只发一条 INSERT,
 * 不再先按主键 SELECT; 读出来的实体 save 仍走 merge 更新; 主键重复交给唯一约束拒绝。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class BaseEntityPersistablePostgresTest {
    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");
    static final List<String> STATEMENTS = Collections.synchronizedList(new ArrayList<>());
    static EntityManagerFactory factory;
    static PersistableProbeRepository repository;
    static TransactionTemplate transactions;
    static JdbcTemplate jdbc;

    @BeforeAll static void start() {
        POSTGRES.start();
        var target = new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        jdbc = new JdbcTemplate(target);
        jdbc.execute("""
                CREATE TABLE persistable_probe(id uuid PRIMARY KEY, name text,
                    created_at timestamptz, updated_at timestamptz, created_by uuid, updated_by uuid)
                """);
        var counting = new DelegatingDataSource(target) {
            @Override public Connection getConnection() throws java.sql.SQLException {
                Connection connection = super.getConnection();
                return (Connection) Proxy.newProxyInstance(Connection.class.getClassLoader(),
                        new Class<?>[] {Connection.class}, (proxy, method, args) -> {
                            if (method.getName().startsWith("prepare") && args != null && args[0] instanceof String sql) {
                                STATEMENTS.add(sql.strip().toLowerCase(Locale.ROOT));
                            }
                            try { return method.invoke(connection, args); }
                            catch (java.lang.reflect.InvocationTargetException failure) { throw failure.getCause(); }
                        });
            }
        };
        var bean = new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(counting);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.testprobe.persistable");
        var props = new Properties(); props.setProperty("hibernate.hbm2ddl.auto", "none");
        bean.setJpaProperties(props); bean.afterPropertiesSet(); factory = bean.getObject();
        var em = SharedEntityManagerCreator.createSharedEntityManager(factory);
        repository = new JpaRepositoryFactory(em).getRepository(PersistableProbeRepository.class);
        transactions = new TransactionTemplate(new JpaTransactionManager(factory));
    }
    @AfterAll static void stop() { if (factory != null) factory.close(); POSTGRES.stop(); }
    @BeforeEach void reset() { STATEMENTS.clear(); }

    @Test void newEntitySaveIsOneInsertWithoutPrimaryKeyLookup() {
        var probe = new PersistableProbe();
        probe.setName("新建");
        assertTrue(probe.isNew(), "A freshly constructed entity with its preset UUID is new");
        transactions.executeWithoutResult(status -> repository.save(probe));
        assertEquals(List.of("insert"), verbs(), "save(new) must not SELECT by primary key first: " + STATEMENTS);
        assertFalse(probe.isNew(), "After the insert the same instance is no longer new");
        assertEquals("新建", jdbc.queryForObject("SELECT name FROM persistable_probe WHERE id=?", String.class, probe.getId()));
    }

    @Test void loadedEntitiesStillMergeAndDetachedCopiesStillUpdate() {
        var probe = new PersistableProbe();
        probe.setName("原值");
        transactions.executeWithoutResult(status -> repository.save(probe));
        var loaded = transactions.execute(status -> repository.findById(probe.getId()).orElseThrow());
        assertFalse(loaded.isNew(), "@PostLoad marks database rows as existing");
        loaded.setName("改过");
        STATEMENTS.clear();
        transactions.executeWithoutResult(status -> repository.save(loaded));
        assertTrue(verbs().contains("update") && !verbs().contains("insert"), "A detached loaded entity merges: " + STATEMENTS);
        assertEquals("改过", jdbc.queryForObject("SELECT name FROM persistable_probe WHERE id=?", String.class, probe.getId()));
        STATEMENTS.clear();
        transactions.executeWithoutResult(status -> {
            var managed = repository.findById(probe.getId()).orElseThrow();
            managed.setName("再改");
            repository.save(managed);
        });
        assertEquals(1, verbs().stream().filter("update"::equals).count());
        assertEquals("再改", jdbc.queryForObject("SELECT name FROM persistable_probe WHERE id=?", String.class, probe.getId()));
    }

    @Test void duplicatePrimaryKeyIsRejectedByTheDatabaseNotSilentlyMerged() {
        var original = new PersistableProbe();
        original.setName("原有");
        transactions.executeWithoutResult(status -> repository.save(original));
        var duplicate = new PersistableProbe();
        duplicate.setId(original.getId());
        duplicate.setName("冒名");
        assertThrows(RuntimeException.class,
                () -> transactions.executeWithoutResult(status -> repository.saveAndFlush(duplicate)));
        assertEquals("原有", jdbc.queryForObject("SELECT name FROM persistable_probe WHERE id=?", String.class,
                original.getId()), "A new instance with an existing UUID must never overwrite that row");
    }

    private static List<String> verbs() {
        return STATEMENTS.stream().map(sql -> sql.split("\\s+", 2)[0]).toList();
    }
}
