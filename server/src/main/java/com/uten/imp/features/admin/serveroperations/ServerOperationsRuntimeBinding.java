package com.uten.imp.features.admin.serveroperations;

import com.uten.imp.common.storage.StorageService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import javax.sql.DataSource;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

/** Internal attestation from the actual connection and active storage bean, never an HTTP input. */
@Component
@RequiredArgsConstructor
public class ServerOperationsRuntimeBinding {
    private final DataSource dataSource;
    private final StorageService storage;
    private final StorageProperties properties;

    public Map<String,Object> capture() {
        try (var connection=dataSource.getConnection(); var statement=connection.createStatement()) {
            statement.setQueryTimeout(5);
            try (var row=statement.executeQuery("SELECT current_database() AS database, "
                    + "coalesce(host(inet_server_addr()),'unix') AS host, current_setting('port')::integer AS port, "
                    + "pg_postmaster_start_time() AS postmaster_started_at, current_schema() AS schema")) {
                if (!row.next()) throw new IllegalStateException();
                String database=row.getString("database"),host=row.getString("host");int port=row.getInt("port");
                var postmaster=row.getObject("postmaster_started_at",java.time.OffsetDateTime.class);
                String provider=storage.backend();
                if (!"public".equals(row.getString("schema"))
                        || database==null || database.isBlank() || database.length()>63 || host==null || host.isBlank()
                        || host.length()>128 || port<1 || port>65535 || postmaster==null || provider==null
                        || !Set.of("internal","local","oss","disabled").contains(provider)) throw new IllegalStateException();
                String mediaRoot=switch(provider) {
                    case "internal" -> realRoot(properties.getInternal().getRoot());
                    case "local" -> realRoot(properties.getLocalDir());
                    default -> null;
                };
                Map<String,Object> value=new LinkedHashMap<>();
                value.put("database",database);value.put("host",host);value.put("port",port);
                value.put("storageProvider",provider);value.put("mediaRoot",mediaRoot);
                value.put("legacyLocalEnabled",properties.isLegacyLocalReadEnabled());
                value.put("legacyLocalRoot",properties.isLegacyLocalReadEnabled()?realRoot(properties.getLocalDir()):null);
                value.put("postmasterStartedAt",postmaster.toInstant().toString());
                return java.util.Collections.unmodifiableMap(value);
            }
        } catch (Exception unavailable) {
            // JDBC errors may contain URLs or credentials. Neither a cause nor a configuration value escapes.
            throw new ApiException(ErrorCode.SERVER_OPERATIONS_UNAVAILABLE,
                    "无法核对当前数据库与附件存储身份，未提交更新；请联系管理员核查部署配置");
        }
    }

    private static String realRoot(String value) throws java.io.IOException {
        if (value==null || value.isBlank()) throw new IllegalStateException();
        Path path=Path.of(value).toAbsolutePath().normalize().toRealPath();
        if (!java.nio.file.Files.isDirectory(path) || !java.nio.file.Files.isReadable(path)) throw new IllegalStateException();
        return path.toString();
    }
}
