package com.uten.imp.legacy.reader;

import com.uten.imp.legacy.config.LegacyProperties;
import com.zaxxer.hikari.HikariDataSource;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.util.List;

/**
 * 从老库 SQL Server 读 SystemItem 分类树。
 * <p><b>按需连接</b>：每次调用建一次性 Hikari 连接池，读完即关——不注册常驻 DataSource bean，
 * 避免触发 Spring Boot 主数据源自动配置退让。
 */
@Component
@Profile("!dev")
public class LegacySystemItemReader implements LegacyCategorySource {

    private final LegacyProperties props;

    public LegacySystemItemReader(LegacyProperties props) {
        this.props = props;
    }

    /** 读指定 ItemclassID 的全部分类行（含 ParentID，供 Java 端组装树）。 */
    public List<LegacyCategoryRow> readCategoryTree(int itemClassId) {
        DataSource ds = openDataSource();
        try {
            JdbcTemplate jdbc = new JdbcTemplate(ds);
            String sql = """
                    SELECT ItemID, ISNULL(ParentID, 0) AS ParentID,
                           ISNULL(Number, '') AS Number, ISNULL(Name, '') AS Name
                    FROM SystemItem
                    WHERE ItemclassID = ?
                    ORDER BY ItemID
                    """;
            return jdbc.query(sql,
                    (rs, i) -> new LegacyCategoryRow(
                            rs.getInt("ItemID"),
                            rs.getInt("ParentID"),
                            rs.getString("Number").trim(),
                            rs.getString("Name").trim()),
                    itemClassId);
        } finally {
            if (ds instanceof AutoCloseable c) {
                try { c.close(); } catch (Exception ignored) { /* 关连接池 */ }
            }
        }
    }

    private DataSource openDataSource() {
        if (!props.isEnabled() || props.getDatasourceUrl() == null || props.getDatasourceUrl().isBlank()) {
            throw new IllegalStateException(
                    "老库迁移未启用：请在环境变量配 UTEN_LEGACY_ENABLED=true 与 UTEN_LEGACY_DB_URL" +
                    "（dev 默认指向本机 LocalDB 的 YTDQ_2023）");
        }
        HikariDataSource ds = new HikariDataSource();
        ds.setPoolName("legacy-migration");
        ds.setJdbcUrl(props.getDatasourceUrl());
        if (props.getDatasourceUsername() != null && !props.getDatasourceUsername().isBlank()) {
            ds.setUsername(props.getDatasourceUsername());
        }
        if (props.getDatasourcePassword() != null && !props.getDatasourcePassword().isBlank()) {
            ds.setPassword(props.getDatasourcePassword());
        }
        ds.setMaximumPoolSize(5);
        ds.setReadOnly(true);
        return ds;
    }
}
