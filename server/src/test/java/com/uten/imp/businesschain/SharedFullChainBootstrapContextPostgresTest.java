package com.uten.imp.businesschain;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Order;
import org.junit.jupiter.api.TestMethodOrder;
import org.junit.jupiter.api.MethodOrderer;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;

/** Shared-database contexts preserve the single bootstrap binding across cache eviction. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
 "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
 "uten.inventory.value-work.enabled=false","uten.features.goods-owner-scope-enabled=false",
 "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
 "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
 "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
 "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
 "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SharedFullChainBootstrapContextPostgresTest {
 @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
 @Autowired JdbcTemplate db;
 @Autowired com.uten.imp.config.props.BootstrapProperties bootstrap;
 @Autowired org.springframework.security.crypto.password.PasswordEncoder passwordEncoder;
 private static UUID originalAccount;
 private static String originalStoredAccount;
 @Test @Order(1)
 @org.springframework.test.annotation.DirtiesContext(methodMode=org.springframework.test.annotation.DirtiesContext.MethodMode.AFTER_METHOD)
 void firstContextHasExactlyOneBootstrapAccountForTheSeedEmployee(){
   originalAccount=db.queryForObject("SELECT u.id FROM users u JOIN employees e ON e.id=u.employee_id WHERE e.code='ADMIN' AND NOT u.is_deleted",UUID.class);
   originalStoredAccount=storedAccount();assertBootstrap();
 }
 @Test @Order(2) void laterContextsKeepTheSameBootstrapIdentityAndDoNotCreateAnotherBinding(){
   assertBootstrap();assertThat(storedAccount()).isEqualTo(originalStoredAccount);
 }
 private void assertBootstrap(){
   assertThat(db.queryForObject("SELECT count(*) FROM users u JOIN employees e ON e.id=u.employee_id WHERE e.code='ADMIN' AND NOT u.is_deleted",Long.class)).isEqualTo(1L);
   assertThat(db.queryForObject("SELECT id FROM users WHERE login_account='full-chain-bootstrap-admin-test' AND NOT is_deleted",UUID.class)).isEqualTo(originalAccount);
   assertThat(db.queryForObject("SELECT is_super_admin AND must_change_password FROM users WHERE id=?",Boolean.class,originalAccount)).isTrue();
   String storedHash=db.queryForObject("SELECT password_hash FROM users WHERE id=?",String.class,originalAccount);
   assertThat(passwordEncoder.matches(bootstrap.getAdminPassword(),storedHash)).as("Shared bootstrap credential agrees with the canonical fixture regardless of context order").isTrue();
 }
 private String storedAccount(){return db.queryForObject("SELECT encode(digest(to_jsonb(u)::text,'sha256'),'hex') FROM users u WHERE id=?",String.class,originalAccount);}
}
