package com.uten.imp.businesschain;
import com.uten.imp.support.MigratedSchemaBaseline;
import com.uten.imp.testsupport.FixtureDatabaseProperties;
import java.nio.file.Files;
import java.util.Locale;
import java.util.concurrent.ConcurrentHashMap;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.*;
import org.springframework.test.context.support.AbstractTestExecutionListener;

/** Uses the existing migrated template; closes each context before releasing its owned clone. */
public final class FinanceScopedChainDatabase {
    private static final ConcurrentHashMap<Class<?>,MigratedSchemaBaseline.ScopedDatabase> OWNED=new ConcurrentHashMap<>();
    private FinanceScopedChainDatabase() { }
    public static void register(DynamicPropertyRegistry registry,Class<?> owner){
        try{
            var lease=OWNED.computeIfAbsent(owner,type->{
                try{
                    String simple=type.getSimpleName().toLowerCase(Locale.ROOT);
                    String label="finance_"+simple.substring(0,Math.min(14,simple.length()))+"_"
                        +Integer.toUnsignedString(type.getName().hashCode(),36);
                    return MigratedSchemaBaseline.openDatabase(label);
                }
                catch(Exception error){throw new IllegalStateException("Cannot open owned finance fixture",error);}
            });
            FixtureDatabaseProperties.bindSameRole(registry,lease::getJdbcUrl,lease::getUsername,lease::getPassword);
            String storage=Files.createTempDirectory("uten-finance-chain-").toString();
            registry.add("uten.storage.local-dir",()->storage);
            registry.add("uten.bootstrap.admin-login",()->FullChainEndToEndTest.SHARED_ADMIN_LOGIN);
            registry.add("uten.bootstrap.admin-password",()->FullChainEndToEndTest.SHARED_ADMIN_PASSWORD);
            registry.add("uten.jwt.secret",()->FullChainEndToEndTest.SHARED_JWT_SECRET);
            registry.add("uten.crypto.pgp-master-key",()->FullChainEndToEndTest.SHARED_PGP_KEY);
            registry.add("uten.crypto.hmac-key",()->FullChainEndToEndTest.SHARED_HMAC_KEY);
        }catch(Exception error){throw new IllegalStateException("Cannot prepare owned finance fixture",error);}
    }
    public static final class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder(){return 1900;}
        @Override public void afterTestClass(TestContext context)throws Exception{
            var lease=OWNED.get(context.getTestClass());if(lease==null)return;
            if(!context.hasApplicationContext())
                throw new IllegalStateException("Finance fixture context did not remain available; retain its owned clone without reloading it");
            // A Mockito-spied primary DataSource can lose Spring's inferred
            // destroy method. Capture only this context's actual owned pool
            // before closing the context; never reopen it or enumerate others.
            var data=context.getApplicationContext().getBean("dataSource",javax.sql.DataSource.class);
            var pool=data instanceof com.zaxxer.hikari.HikariDataSource hikari?hikari:
                data.unwrap(com.zaxxer.hikari.HikariDataSource.class);
            if(pool==null||!java.util.Objects.equals(pool.getJdbcUrl(),lease.getJdbcUrl()))
                throw new IllegalStateException("Finance fixture cleanup cannot claim a different datasource");
            context.markApplicationContextDirty(DirtiesContext.HierarchyMode.EXHAUSTIVE);
            if(!pool.isClosed())pool.close();
            if(!pool.isClosed())throw new IllegalStateException("Owned finance fixture pool is still open after context shutdown");
            lease.close();
            OWNED.remove(context.getTestClass(),lease);
        }
    }
}
