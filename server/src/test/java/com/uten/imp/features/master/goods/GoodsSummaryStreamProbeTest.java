package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.readsnapshot.BoundedMasterReadSource;
import com.uten.imp.common.web.CompleteReadBatchPlan;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.goods.dto.GoodsListItem;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.mould.MouldRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

import java.sql.Connection;
import java.util.*;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

/**
 * Opt-in measurement probe (2026-11-09 货品资料 3.9 万行加载慢定位) against the real
 * developer database, READ ONLY: drives the production {@link GoodsService#list}
 * batches through the shared {@link BoundedMasterReadSource} cursor exactly like
 * {@code MasterSummaryReadSupport.stream} does (same plan ladder + em.clear per
 * batch + one Jackson frame per batch), and reports per-batch timings grouped by
 * batch size so fixed per-batch overhead versus per-row cost is visible.
 * Run: UTEN_GOODS_STREAM_PROBE=true with UTEN_DB_URL/UTEN_DB_USER/UTEN_DB_PASSWORD set.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_GOODS_STREAM_PROBE", matches = "(?i)true")
class GoodsSummaryStreamProbeTest {

    private static EntityManagerFactory factory;
    private static EntityManager em;
    private static TransactionTemplate transactions;
    private static GoodsService service;
    private static final ObjectMapper json = new ObjectMapper().findAndRegisterModules();

    @BeforeAll static void start() {
        System.out.printf("GOODS_STREAM_PROBE env url=%s user=%s password=%s%n",
                System.getenv("UTEN_DB_URL"), System.getenv("UTEN_DB_USER"),
                System.getenv("UTEN_DB_PASSWORD") == null ? null : "<set>");
        var ds = new DriverManagerDataSource(System.getenv("UTEN_DB_URL"),
                System.getenv("UTEN_DB_USER"), System.getenv("UTEN_DB_PASSWORD"));
        var bean = new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(ds);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp");
        var props = new Properties();
        props.setProperty("hibernate.hbm2ddl.auto", "none");
        props.setProperty("hibernate.jdbc.time_zone", "UTC");
        // Boot must not need a metadata connection; the probe's database is PostgreSQL.
        props.setProperty("hibernate.dialect", "org.hibernate.dialect.PostgreSQLDialect");
        props.setProperty("hibernate.connection.isolation",
                String.valueOf(Connection.TRANSACTION_REPEATABLE_READ));
        bean.setJpaProperties(props);
        bean.afterPropertiesSet();
        factory = bean.getObject();
        em = SharedEntityManagerCreator.createSharedEntityManager(factory);
        var manager = new JpaTransactionManager(factory);
        transactions = new TransactionTemplate(manager);
        transactions.setIsolationLevel(TransactionDefinition.ISOLATION_REPEATABLE_READ);
        transactions.setReadOnly(true);
        transactions.setTimeout(300);

        var repositories = new JpaRepositoryFactory(em);
        var relationships = mock(GoodsMasterRelationshipResolver.class);
        when(relationships.warehouseNames(any())).thenReturn(Map.of());
        when(relationships.departmentNames(any())).thenReturn(Map.of());
        var costMasker = mock(GoodsCostMasker.class);
        when(costMasker.canView()).thenReturn(false);
        service = new GoodsService(
                repositories.getRepository(GoodsRepository.class),
                repositories.getRepository(MaterialCategoryRepository.class),
                repositories.getRepository(ColorRepository.class),
                repositories.getRepository(UnitRepository.class),
                repositories.getRepository(MouldRepository.class),
                mock(TxSessionVars.class),
                em,
                mock(CategoryDrivenCodeService.class),
                mock(OwnerVisibility.class),
                mock(SecurityContextCurrentUser.class),
                costMasker,
                relationships);
    }

    @AfterAll static void stop() {
        if (factory != null) factory.close();
    }

    /** The goods page's 「全部货品」 read: no category, no keyword, no header filter. */
    private static final GoodsQueryFilter ALL_GOODS = new GoodsQueryFilter(
            null, null, null, Set.of(), null, null, null, null, null, null, null, null, null,
            null, null, null, null, null, null, null, null, null, null, null, null, Map.of(),
            null, null, null);

    private record Batch(int index, int size, long listMs, long jsonMs, long bytes) { }

    private record Probe(long totalMs, long countMs, List<Batch> batches, long rows, long total,
            List<String> head, List<String> tail) { }

    private Probe probe(String label, CompleteReadBatchPlan plan) {
        return transactions.execute(status -> {
            try (var cursor = BoundedMasterReadSource.open(em, () -> { }, ignored -> { })) {
                var batches = new ArrayList<Batch>();
                var head = new ArrayList<String>();
                var tail = new ArrayDeque<String>();
                long seen = 0, expected = -1, countMs = 0;
                long start = System.nanoTime();
                int index = 0;
                while (true) {
                    int size = plan.sizeAt(seen), page = plan.pageAt(seen);
                    long b0 = System.nanoTime();
                    PageResponse<GoodsListItem> value = service.list(ALL_GOODS, page, size, null, null);
                    long b1 = System.nanoTime();
                    byte[] encoded;
                    try {
                        encoded = json.writeValueAsBytes(Map.of("type", "page", "value", value));
                    } catch (java.io.IOException failure) {
                        throw new IllegalStateException(failure);
                    }
                    long b2 = System.nanoTime();
                    if (expected < 0) expected = value.getTotal();
                    else assertThat(value.getTotal()).isEqualTo(expected);
                    for (GoodsListItem item : value.getItems()) {
                        if (head.size() < 3) head.add(item.getCode());
                        tail.addLast(item.getCode());
                        if (tail.size() > 3) tail.removeFirst();
                    }
                    seen += value.getItems().size();
                    assertThat(seen).isLessThanOrEqualTo(expected);
                    countMs += (b1 - b0) / 1_000_000;
                    batches.add(new Batch(index++, size, (b1 - b0) / 1_000_000,
                            (b2 - b1) / 1_000_000, encoded.length));
                    cursor.clearBatch();
                    if (seen == expected) break;
                }
                long totalMs = (System.nanoTime() - start) / 1_000_000;
                report(label, new Probe(totalMs, countMs, batches, seen, expected,
                        List.copyOf(head), List.copyOf(tail)));
                return new Probe(totalMs, countMs, batches, seen, expected,
                        List.copyOf(head), List.copyOf(tail));
            }
        });
    }

    private static void report(String label, Probe probe) {
        Map<Integer, List<Batch>> bySize = new TreeMap<>();
        for (Batch batch : probe.batches()) bySize.computeIfAbsent(batch.size(), ignored -> new ArrayList<>()).add(batch);
        StringBuilder groups = new StringBuilder();
        for (var entry : bySize.entrySet()) {
            var list = entry.getValue();
            long listMs = list.stream().mapToLong(Batch::listMs).sum();
            long jsonMs = list.stream().mapToLong(Batch::jsonMs).sum();
            long first = list.get(0).listMs();
            double avgList = (double) listMs / list.size();
            groups.append(String.format(Locale.ROOT,
                    "%nGOODS_STREAM_PROBE   size=%4d batches=%4d list_ms=%6d (first=%4d avg=%.1f) json_ms=%6d",
                    entry.getKey(), list.size(), listMs, first, avgList, jsonMs));
        }
        System.out.printf(Locale.ROOT,
                "GOODS_STREAM_PROBE %s rows=%d total=%d batches=%d wall_ms=%d list_ms=%d json_ms=%d head=%s tail=%s%s%n",
                label, probe.rows(), probe.total(), probe.batches().size(), probe.totalMs(),
                probe.countMs(), probe.batches().stream().mapToLong(Batch::jsonMs).sum(),
                probe.head(), probe.tail(), groups);
    }

    @Test void progressiveLadderPhases() {
        // Current production plan: 50 first, then aligned growth to the shared max.
        var progressive = probe("progressive-50-sharedmax", CompleteReadBatchPlan.PROGRESSIVE);
        // Same rows through one fixed 200-row frame plan (the pre-progressive shape).
        var fixed = probe("fixed-200", CompleteReadBatchPlan.fixed(200));
        assertThat(fixed.rows()).isEqualTo(progressive.rows());
        assertThat(fixed.head()).isEqualTo(progressive.head());
        assertThat(fixed.tail()).isEqualTo(progressive.tail());
    }
}
