package com.uten.imp.businesschain;

import com.uten.imp.support.MigratedSchemaBaseline;
import com.uten.imp.support.MigratedSchemaContextInitializer;
import com.zaxxer.hikari.HikariDataSource;
import com.zaxxer.hikari.HikariPoolMXBean;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.test.context.*;
import org.springframework.test.context.support.AbstractTestExecutionListener;

/** One private database lease per real Spring context; pools close before that lease. */
public final class FinanceScopedChainDatabase {
    static final String LEASE_BEAN="financeScopedChainDatabaseLease";
    private FinanceScopedChainDatabase() { }

    public static void register(DynamicPropertyRegistry registry,Class<?> owner) {
        Objects.requireNonNull(owner,"Finance fixture owner");
        try {
            String storage=Files.createTempDirectory("uten-finance-chain-").toString();
            registry.add("uten.storage.local-dir",()->storage);
            registry.add("uten.bootstrap.admin-login",()->FullChainEndToEndTest.SHARED_ADMIN_LOGIN);
            registry.add("uten.bootstrap.admin-password",()->FullChainEndToEndTest.SHARED_ADMIN_PASSWORD);
            registry.add("uten.jwt.secret",()->FullChainEndToEndTest.SHARED_JWT_SECRET);
            registry.add("uten.crypto.pgp-master-key",()->FullChainEndToEndTest.SHARED_PGP_KEY);
            registry.add("uten.crypto.hmac-key",()->FullChainEndToEndTest.SHARED_HMAC_KEY);
        } catch(java.io.IOException failure) {
            throw new IllegalStateException("Cannot prepare finance fixture storage",failure);
        }
    }

    public static final class Initializer extends MigratedSchemaContextInitializer {
        @Override protected String databaseLabel() { return "finance_chain"; }
        @Override protected String leaseBeanName() { return LEASE_BEAN; }
    }

    /** Evidence only: observes already-created pools without reopening a retired context. */
    public static final class BoundaryEvidence extends AbstractTestExecutionListener {
        private static final String KEY=BoundaryEvidence.class.getName();
        private record Pool(String name,HikariDataSource source,HikariPoolMXBean physical) { }
        private record Boundary(ConfigurableApplicationContext context,List<Pool> pools) { }
        @Override public int getOrder() { return 1000; }
        @Override public void beforeTestMethod(TestContext context) throws Exception { capture(context); }
        @Override public void afterTestExecution(TestContext context) throws Exception { capture(context); }

        @SuppressWarnings("unchecked")
        private static void capture(TestContext test) throws Exception {
            if(!test.hasApplicationContext()) { return; }
            var context=(ConfigurableApplicationContext)test.getApplicationContext();
            if(!context.isActive()) { return; }
            var boundaries=(List<Boundary>)test.getAttribute(KEY);
            if(boundaries==null) { boundaries=new ArrayList<>();test.setAttribute(KEY,boundaries); }
            Boundary current=null;
            for(var boundary:boundaries) { if(boundary.context()==context) { current=boundary;break; } }
            if(current==null) { current=new Boundary(context,new ArrayList<>());boundaries.add(current); }
            var factory=context.getBeanFactory();
            var lease=context.getBean(LEASE_BEAN,MigratedSchemaBaseline.ScopedDatabase.class);
            for(String name:factory.getSingletonNames()) {
                if(!(factory.getSingleton(name) instanceof javax.sql.DataSource source)) { continue; }
                var pool=source instanceof HikariDataSource hikari?hikari:source.unwrap(HikariDataSource.class);
                if(!Objects.equals(pool.getJdbcUrl(),lease.getJdbcUrl())) {
                    throw new IllegalStateException("Finance boundary cannot claim a foreign datasource");
                }
                boolean known=false;
                for(var recorded:current.pools()) { if(recorded.source()==pool) { known=true;break; } }
                if(!known) { current.pools().add(new Pool(name,pool,pool.getHikariPoolMXBean())); }
            }
        }

        @Override @SuppressWarnings("unchecked")
        public void afterTestClass(TestContext test) {
            var boundaries=(List<Boundary>)test.removeAttribute(KEY);
            if(boundaries==null) { return; }
            for(var boundary:boundaries) {
                if(boundary.context().isActive()) { throw new IllegalStateException("Finance context did not retire at class boundary"); }
                for(var pool:boundary.pools()) {
                    var physical=pool.physical()==null?pool.source().getHikariPoolMXBean():pool.physical();
                    int total=physical==null?0:physical.getTotalConnections();
                    System.out.println("FINANCE_CONTEXT_BOUNDARY owner="+test.getTestClass().getSimpleName()+" pool="
                        +pool.name()+" closed="+pool.source().isClosed()+" actualConnections="+total);
                    if(!pool.source().isClosed()||total!=0) {
                        throw new IllegalStateException("Finance context left an actual pool alive: "+pool.name());
                    }
                }
            }
        }
    }
}
