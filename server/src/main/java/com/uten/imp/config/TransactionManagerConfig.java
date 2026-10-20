package com.uten.imp.config;

import javax.sql.DataSource;

import jakarta.persistence.EntityManagerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.orm.jpa.JpaTransactionManager;

/**
 * 事务管理器口径：恢复 JDBC savepoint（嵌套事务）能力。
 *
 * <p>Spring Boot 4 自动装配的 {@link JpaTransactionManager} 默认
 * nestedTransactionAllowed=false，PROPAGATION_NESTED 退化为 REQUIRED：
 * 业务里被捕获的语句级失败（如员工 PII 解密「Wrong key or corrupt data」的逐条
 * 兜底重试）会令 PostgreSQL 把整笔事务置为 aborted，提交时抛
 * UnexpectedRollbackException。Boot 3 时代由 JdbcTransactionManager 子类提供
 * savepoint；Spring 7 已将该类与 JPA 解耦，这里对 JpaTransactionManager 显式
 * 开启嵌套支持并绑定同一 DataSource，让 Hibernate 方言经 JDBC 连接建立保存点。</p>
 */
@Configuration(proxyBeanMethods = false)
public class TransactionManagerConfig {

    @Bean
    JpaTransactionManager transactionManager(EntityManagerFactory entityManagerFactory, DataSource dataSource) {
        JpaTransactionManager manager = new JpaTransactionManager(entityManagerFactory);
        manager.setDataSource(dataSource);
        manager.setNestedTransactionAllowed(true);
        return manager;
    }
}
