package com.uten.imp.features.rbac.directory;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.rbac.directory.AiChatFeatureDirectory.Feature;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * The permission catalog is the migrated {@code permissions} table: every code the directory names resolves to a
 * Chinese name there, and the tools read those names (SPEC P1-1, P1-4).
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class AiFeatureAccessPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static JdbcTemplate jdbc;
    private static final AiChatFeatureDirectory DIRECTORY = new AiChatFeatureDirectory(new ObjectMapper());

    @BeforeAll
    static void open() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("ai_feature_access");
        jdbc = new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword()));
    }

    @AfterAll
    static void close() throws Exception {
        if (database != null) database.close();
    }

    private static AiFeatureAccess access(Set<String> permissions, Set<String> domains) {
        AiChatAccessPolicy policy = mock(AiChatAccessPolicy.class);
        when(policy.requireChat()).thenReturn(new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "reader", permissions, false, true, false));
        when(policy.domains()).thenReturn(domains);
        return new AiFeatureAccess(DIRECTORY, policy, jdbc);
    }

    @Test
    void everyCodeTheDirectoryNamesHasACatalogName() {
        Set<String> codes = new TreeSet<>();
        for (Feature feature : DIRECTORY.features()) {
            if (feature.anyOf() != null) codes.addAll(feature.anyOf());
            codes.addAll(feature.allOf());
        }
        var names = access(Set.of(), Set.of("SELF")).names(codes);
        assertThat(codes).hasSizeGreaterThan(50);
        assertThat(new TreeSet<>(names.keySet())).as("目录里的权限码都要在权限目录里有中文名称").isEqualTo(codes);
        names.values().forEach(name -> assertThat(name.name()).as(name.code()).isNotBlank().doesNotContain(":"));
        assertThat(access(Set.of(), Set.of("SELF")).catalog()).hasSizeGreaterThan(300);
    }

    @Test
    void theToolsAnswerWithTheCatalogNames() {
        AiFeatureAccess clerk = access(Set.of("ai:use", "stock:view", "stock_doc:view"), Set.of("SELF", "WAREHOUSE"));
        String stock = (String) new FeatureDirectoryAiChatTool(clerk).execute(Map.of("keyword", "库存")).get("reply");
        assertThat(stock).contains("即时库存(仓库管理)", "库存分析(仓库管理)：你暂时打不开，缺少「查看仓库报表」权限");
        String purchase = (String) new FeatureDirectoryAiChatTool(clerk).execute(Map.of("keyword", "采购订货单")).get("reply");
        assertThat(purchase).contains("采购订货单列表(采购管理)：你暂时打不开，缺少「查看采购订货」权限")
                .doesNotContain("相关权限");
        MyAccessAiChatTool explain = new MyAccessAiChatTool(clerk);
        assertThat((String) explain.execute(Map.of("target", "缺少操作权限：sales_order:approve")).get("reply"))
                .isEqualTo("你还没有「审核销售订货单」权限(属于「销售管理 · 销售订货」)。\n请联系管理员开通。");
        assertThat((String) explain.execute(Map.of("target", "我为什么打不开财务报表")).get("reply"))
                .contains("缺少「查看钱流报表」权限").endsWith("请联系管理员开通。");
        String personnel = (String) explain.execute(Map.of("target", "缺少操作权限：payroll:view:all")).get("reply");
        assertThat(personnel).contains("需要管理员开通相关权限").doesNotContain("查看全员工资条");
        AiFeatureAccess payrollClerk = access(Set.of("ai:use", "employee:view"), Set.of("SELF", "HR"));
        assertThat((String) new MyAccessAiChatTool(payrollClerk).execute(Map.of("target", "缺少操作权限：payroll:view:all")).get("reply"))
                .contains("你还没有「查看全员工资条」权限");
    }
}
