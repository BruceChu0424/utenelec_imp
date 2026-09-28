package com.uten.imp.features.master.learning;

import com.uten.imp.common.text.IntakeTextNormalizer;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Java {@link IntakeTextNormalizer#normalizePart} 与迁移里两处 SQL 表达式(历史客户型号播种、
 * 型号索引 idx_goods_model_norm)以及主档召回查询逐字等价: 在真实 PostgreSQL 16 上对一批刁钻样本
 * (全角、各种横线、不间断空格、全角空格、制表/换行、结尾句点、连字、上标、带圈数字、希腊/西里尔/
 * 德语/土耳其字母、组合字符)逐个比对。任一不一致, 播种出来的对照或召回的型号就会对不上。
 *
 * <p>用 Debian(glibc)镜像: 正式环境的 PostgreSQL 由 apt 安装在 glibc 系统上; PostgreSQL 正则的
 * {@code \s} 对少数罕见空白字符(U+0085、U+1680)按 C 库分类, musl 与 glibc 本身就不一致。
 *
 * <p>门控 {@code UTEN_RUN_DB_TESTS=true}(需要 Docker)。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class IntakeNormalizerSqlParityPostgresTest {

    private static PostgreSQLContainer<?> postgres;

    /** 必须完全一致的样本(用转义写出, 避免源码里出现看不见的字符)。 */
    static final List<String> SAMPLES = List.of(
            "GZ23/D",
            "gz23/d",
            "  GZ23 / D. ",
            "GZ23/D..",
            "GZ23.D",
            "\uFF27\uFF3A\uFF12\uFF13\uFF0F\uFF24\uFF0E",
            "Q120\uFF0DK20AD",
            "Q120\u2014K20AD",
            "Q120\u2013K20AD",
            "K20AD\u201001",
            "K20AD\u201101",
            "G-M/D",
            "GK11Z13ND/2",
            "WTV-03+WTV-04+WTV-05",
            "TEL-02+TEL-02-W+PC-03",
            "Z13N\t-03",
            "Z13N\n-03",
            "Z13N\r\n-03",
            "Z13N\u000B-03",
            "Z13N\f-03",
            "Z13N\u00A0-03",
            "Z13N\u3000-03",
            "Z13N\u2003-03",
            "Z13N\u2007-03",
            "Z13N\u2009-03",
            "Z13N\u202F-03",
            "Z13N\u205F-03",
            "Z13N\u200B-03",
            "GZ23/D.\n",
            "GZ23/D.\u3000",
            "Z13N\u0085-03",
            "Z13N\u1680-03",
            "Z13N\u2028-03",
            "Z13N\u2029-03",
            "GZ23/D.\u0085",
            "GZ23/D.\u2028",
            "GZ23/D.\u2029",
            "Z13N\u180E-03",
            "Z13N\uFEFF-03",
            "Z13N\u001C-03",
            "\uFB01ne",
            "x\u00B2",
            "\u2460\u2461",
            "\u216B-01",
            "straße",
            "ıi",
            "σς",
            "свет-01",
            "café",
            "cafe\u0301",
            "两开多功能三极插座",
            "型号\uFF1AGK12\uFF08白\uFF09",
            "...",
            ".",
            "",
            "K62-LZ211-02W",
            "Z12Z13/N");

    @BeforeAll
    static void start() {
        postgres = new PostgreSQLContainer<>(
                DockerImageName.parse("postgres:16").asCompatibleSubstituteFor("postgres"))
                .withDatabaseName("uten_parity");
        postgres.start();
    }

    @AfterAll
    static void stop() {
        if (postgres != null) postgres.stop();
    }

    @Test
    void javaNormalizePartEqualsSeedIndexAndLookupExpressionsOnTrickySamples() throws SQLException {
        assertThat(mismatches(SAMPLES)).isEmpty();
    }

    private static List<String> mismatches(List<String> samples) throws SQLException {
        String migration = IntakeModelNormSqlSources.migrationText();
        String seed = IntakeModelNormSqlSources.seedExpression(migration);
        String index = IntakeModelNormSqlSources.indexExpression(migration)
                .replace("coalesce(model, '')", "coalesce(CAST(? AS text), '')");
        String lookup = MasterIntakeLookupAdapter.MODEL_NORM_EXPR.replace("g.model", "CAST(? AS text)");
        assertThat(index).contains("CAST(? AS text)");

        List<String> out = new ArrayList<>();
        try (Connection db = DriverManager.getConnection(
                postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword());
             PreparedStatement statement = db.prepareStatement(
                     "SELECT " + seed + ", " + index + ", " + lookup)) {
            for (String sample : samples) {
                statement.setString(1, sample);
                statement.setString(2, sample);
                statement.setString(3, sample);
                try (ResultSet row = statement.executeQuery()) {
                    row.next();
                    String java = IntakeTextNormalizer.normalizePart(sample);
                    for (int column = 1; column <= 3; column++) {
                        String sql = row.getString(column);
                        if (!java.equals(sql)) {
                            out.add("sample=" + escape(sample) + " column=" + column
                                    + " java=" + escape(java) + " sql=" + escape(sql));
                        }
                    }
                }
            }
        }
        return out;
    }

    private static String escape(String value) {
        if (value == null) return "null";
        StringBuilder out = new StringBuilder();
        value.codePoints().forEach(cp -> {
            if (cp < 0x20 || cp > 0x7e) out.append(String.format("\\u%04X", cp));
            else out.appendCodePoint(cp);
        });
        return out.toString();
    }
}
