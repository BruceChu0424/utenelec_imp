package com.uten.imp.features.notice;

import org.springframework.jdbc.core.JdbcTemplate;

final class NoticeParticipationSqlFixture {
    static void install(JdbcTemplate jdbc) {
        try (var stream=NoticeParticipationSqlFixture.class.getResourceAsStream(
                "/db/migration/V979__readonly_business_participation.sql")) {
            if(stream==null) throw new IllegalStateException("Missing participation migration");
            String migration=new String(stream.readAllBytes(),java.nio.charset.StandardCharsets.UTF_8);
            jdbc.execute(migration.substring(migration.indexOf("CREATE FUNCTION fn_notice_participation_visible")));
        } catch(java.io.IOException failure) { throw new IllegalStateException(failure); }
    }
}
