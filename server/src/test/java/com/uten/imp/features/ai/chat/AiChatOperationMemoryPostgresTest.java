package com.uten.imp.features.ai.chat;

import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * ADR-163 个人操作记忆在一次性 PostgreSQL 上的表行为: V816 的建表 SQL 手工执行(照既有 DB 测试的内联 DDL
 * 先例, 只补一个 users 占位表; 审计登记与 business_data_reset 锚点依赖完整迁移基线, 不在此重复), 服务
 * 直接用真 JdbcTemplate 驱动。需 Docker 与 {@code UTEN_RUN_DB_TESTS=true}。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class AiChatOperationMemoryPostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID USER = UUID.randomUUID();
    private static JdbcTemplate jdbc;
    private static AiChatOperationMemoryService memory;

    @BeforeAll
    static void start() {
        DB.start();
        var dataSource = new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        jdbc.update("CREATE TABLE users(id uuid PRIMARY KEY)");
        jdbc.update("INSERT INTO users(id) VALUES (?)", USER);
        jdbc.execute("""
                CREATE TABLE ai_chat_operation_memory (
                    id uuid PRIMARY KEY,
                    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    question_key varchar(160) NOT NULL
                        CHECK (btrim(question_key) <> '' AND length(question_key) <= 160),
                    resolution jsonb NOT NULL CHECK (jsonb_typeof(resolution) = 'object' AND octet_length(resolution::text) <= 512
                        AND (resolution->>'kind') IN ('OPEN_FORM', 'TOOL')),
                    hit_count int NOT NULL DEFAULT 1 CHECK (hit_count >= 1),
                    last_used_at timestamptz NOT NULL DEFAULT now(),
                    created_at timestamptz NOT NULL DEFAULT now(),
                    UNIQUE (user_id, question_key)
                )""");
        jdbc.execute("CREATE INDEX idx_ai_chat_operation_memory_recent ON ai_chat_operation_memory(user_id, last_used_at DESC)");
        var access = mock(AiChatAccessPolicy.class);
        when(access.requireChat()).thenReturn(new AuthUser(USER, UUID.randomUUID(), "memory-user",
                Set.of("ai:use"), false, true, false));
        memory = new AiChatOperationMemoryService(jdbc, access, new AiProperties(),
                new DataSourceTransactionManager(dataSource));
    }

    @AfterAll
    static void stop() {
        if (DB != null) DB.stop();
    }

    @BeforeEach void clean() {
        jdbc.update("DELETE FROM ai_chat_operation_memory");
    }

    @Test void repeatedQuestionAccumulatesAndAChangedResolutionStartsOver() {
        memory.remember("帮我创建个销售订货单", "OPEN_FORM", "SALES_ORDER");
        memory.remember("帮我创建个销售订货单", "OPEN_FORM", "SALES_ORDER");
        var remembered = memory.recall("帮我创建个销售订货单").orElseThrow();
        assertThat(remembered.question()).isEqualTo("帮我创建个销售订货单");
        assertThat(remembered.kind()).isEqualTo("OPEN_FORM");
        assertThat(remembered.target()).isEqualTo("SALES_ORDER");
        assertThat(remembered.hitCount()).isEqualTo(2);
        // The same question asked with other punctuation or spacing is the same key, not a new row.
        memory.remember("帮我，创建个 销售订货单！", "OPEN_FORM", "SALES_ORDER");
        assertThat(memory.recall("帮我创建个销售订货单").orElseThrow().hitCount()).isEqualTo(3);
        assertThat(rows()).isEqualTo(1);

        memory.remember("帮我创建个销售订货单", "TOOL", "sales_order_progress");
        var changed = memory.recall("帮我创建个销售订货单").orElseThrow();
        assertThat(changed.kind()).isEqualTo("TOOL");
        assertThat(changed.target()).isEqualTo("sales_order_progress");
        assertThat(changed.hitCount()).isEqualTo(1);
    }

    @Test void aQuestionUnusedBeyondTheRetentionWindowIsNotRecalled() {
        memory.remember("A001 还有多少库存", "TOOL", "inventory_lookup");
        jdbc.update("UPDATE ai_chat_operation_memory SET last_used_at = now() - make_interval(days => 91)");
        assertThat(memory.recall("A001 还有多少库存")).isEmpty();
    }

    @Test void writingPastFiftyRowsKeepsOnlyTheMostRecentlyUsed() {
        for (int i = 1; i <= 50; i++) {
            memory.remember("问题" + i, "TOOL", "tool" + i);
            // Stagger the timestamps so the oldest row is deterministic (remember itself stamps now()).
            jdbc.update("UPDATE ai_chat_operation_memory SET last_used_at = now() - make_interval(mins => ?)"
                    + " WHERE question_key = ?", (51 - i) * 10, "问题" + i);
        }
        assertThat(rows()).isEqualTo(50);
        memory.remember("再来一张订货单", "OPEN_FORM", "SALES_ORDER");
        assertThat(rows()).as("the write-after-write LRU trim keeps at most 50 rows").isEqualTo(50);
        assertThat(count("问题1")).as("the least recently used row is evicted").isZero();
        assertThat(memory.recall("问题2")).isPresent();
        assertThat(memory.recall("再来一张订货单")).isPresent();
    }

    private static long rows() {
        return jdbc.queryForObject("SELECT count(*) FROM ai_chat_operation_memory", Long.class);
    }

    private static long count(String key) {
        return jdbc.queryForObject("SELECT count(*) FROM ai_chat_operation_memory WHERE question_key = ?", Long.class, key);
    }
}
