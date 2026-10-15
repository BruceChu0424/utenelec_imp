package com.uten.imp.features.visitor.sms;

import com.fasterxml.jackson.annotation.JsonIgnore;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/** Singleton configuration; revision remains monotonic when returning to ENV. */
@Repository
public class SmsGatewaySettingsStore {
    public static final UUID ID = UUID.fromString("7f08141b-021b-4f46-9d42-d1db854d1198");
    private final JdbcTemplate jdbc;
    public SmsGatewaySettingsStore(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    public record Row(long version, String mode, String provider, String endpoint, String signName,
                      String templateCode, @JsonIgnore String accessKeyIdCipher, @JsonIgnore String accessKeySecretCipher,
                      String accessKeyIdHint, OffsetDateTime updatedAt, UUID updatedBy) {
        @Override public String toString() { return "SmsSettingsRow[version=" + version + ",mode=" + mode + ",provider=" + provider + "]"; }
    }
    /** Not read-only: cloud routing must never use a stale replica for an external send. */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public Optional<Row> current() { return read(false); }

    @Transactional(propagation = Propagation.MANDATORY)
    public Optional<Row> lockCurrent() {
        jdbc.queryForObject("SELECT pg_advisory_xact_lock(hashtextextended('sms-gateway-settings:v1',0))::text", String.class);
        return read(true);
    }
    private Optional<Row> read(boolean lock) {
        List<Row> rows = jdbc.query("""
                SELECT version,mode,provider,endpoint,sign_name,template_code,access_key_id_cipher,
                       access_key_secret_cipher,access_key_id_hint,updated_at,updated_by
                FROM sms_gateway_settings WHERE id=?
                """ + (lock ? " FOR UPDATE" : ""), (r,n) -> new Row(r.getLong("version"),r.getString("mode"),
                r.getString("provider"),r.getString("endpoint"),r.getString("sign_name"),r.getString("template_code"),
                r.getString("access_key_id_cipher"),r.getString("access_key_secret_cipher"),r.getString("access_key_id_hint"),
                r.getObject("updated_at",OffsetDateTime.class),r.getObject("updated_by",UUID.class)), ID);
        return rows.stream().findFirst();
    }
    @Transactional(propagation = Propagation.MANDATORY)
    public boolean save(Row row, long expectedVersion, boolean existed) {
        if (!existed) return jdbc.update("""
                INSERT INTO sms_gateway_settings(id,version,mode,provider,endpoint,sign_name,template_code,
                     access_key_id_cipher,access_key_secret_cipher,access_key_id_hint,updated_at,updated_by)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO NOTHING
                """,ID,row.version(),row.mode(),row.provider(),row.endpoint(),row.signName(),row.templateCode(),
                row.accessKeyIdCipher(),row.accessKeySecretCipher(),row.accessKeyIdHint(),row.updatedAt(),row.updatedBy()) == 1;
        return jdbc.update("""
                UPDATE sms_gateway_settings SET version=?,mode=?,provider=?,endpoint=?,sign_name=?,template_code=?,
                    access_key_id_cipher=?,access_key_secret_cipher=?,access_key_id_hint=?,updated_at=?,updated_by=?
                WHERE id=? AND version=?
                """,row.version(),row.mode(),row.provider(),row.endpoint(),row.signName(),row.templateCode(),
                row.accessKeyIdCipher(),row.accessKeySecretCipher(),row.accessKeyIdHint(),row.updatedAt(),row.updatedBy(),ID,expectedVersion) == 1;
    }
    public static String idAad() { return "sms_gateway_settings|access_key_id|" + ID; }
    public static String secretAad() { return "sms_gateway_settings|access_key_secret|" + ID; }
}
