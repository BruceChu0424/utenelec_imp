package com.uten.imp.features.dashboard.policy;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.config.props.PolicyIntelligenceProperties;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.net.URI;
import java.net.URLDecoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.ByteBuffer;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Duration;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 官方政策智识服务：仅抓取预设政府 HTTPS 站点（{@link #OFFICIAL_HOSTS} 白名单严格校验，
 * 拒绝站外/非 HTTPS/userinfo/fragment），HTML→文本→DeepSeek 摘要→
 * upsert {@code official_policy_briefs}（按 source_url 去重、SHA-256 去重抓取）。
 */
@Slf4j
@Service
@RequiredArgsConstructor
@ConditionalOnProperty(
        name = "uten.policy-intelligence.enabled",
        havingValue = "true")
public class OfficialPolicyIntelligenceService {

    private static final Set<String> OFFICIAL_HOSTS = Set.of(
            "www.zs.gov.cn",
            "zs.gov.cn",
            "guangdong.chinatax.gov.cn",
            "www.mof.gov.cn",
            "mof.gov.cn",
            "www.gov.cn",
            "gov.cn");
    private static final Pattern LINK_PATTERN = Pattern.compile(
            "(?is)<a\\b[^>]*?href\\s*=\\s*['\"]([^'\"]+)['\"][^>]*>(.*?)</a>");
    private static final Pattern CHARSET_PATTERN = Pattern.compile(
            "(?i)charset\\s*=\\s*['\"]?([a-zA-Z0-9._-]+)");
    private static final Pattern RELEVANT_TEXT = Pattern.compile(
            "补贴|补助|退税|税收|增值税|制造业|出口|申报|检查|抽查|市场监管|"
                    + "安全生产|消防|质量|认证|电器|工业企业");
    private static final int MAX_DOWNLOAD_BYTES = 1_500_000;
    private static final int MAX_MODEL_TEXT = 16_000;

    private final PolicyIntelligenceProperties properties;
    private final DeepSeekPolicySummarizer summarizer;
    private final JdbcTemplate jdbc;
    private final ObjectMapper objectMapper;
    private final HttpClient httpClient = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(8))
            .followRedirects(HttpClient.Redirect.NEVER)
            .build();

    public RefreshResult refresh() {
        if (properties.getApiKey().isBlank()) {
            log.warn("政策情报已启用，但 DEEPSEEK_API_KEY 为空；跳过刷新");
            return new RefreshResult(0, 0, 0);
        }
        Set<URI> candidates = new LinkedHashSet<>();
        for (String indexUrl : properties.getIndexUrls()) {
            URI index = verifiedOfficialUri(indexUrl);
            try {
                String html = fetch(index);
                discoverLinks(index, html, candidates);
            } catch (RuntimeException error) {
                log.warn("官方政策索引读取失败：host={}", index.getHost());
            }
        }
        jdbc.queryForList("""
                SELECT source_url FROM official_policy_briefs
                WHERE status = 'ACTIVE'
                ORDER BY published_on DESC
                LIMIT 30
                """, String.class).stream()
                .map(this::verifiedOfficialUri)
                .forEach(candidates::add);

        int inspected = 0;
        int updated = 0;
        int failed = 0;
        for (URI candidate : candidates) {
            if (inspected >= properties.getMaxCandidates()) break;
            inspected++;
            try {
                String text = htmlToText(fetch(candidate));
                if (text.length() < 100) continue;
                String hash = sha256(text);
                if (alreadyCurrent(candidate.toString(), hash)) continue;
                DeepSeekPolicySummarizer.Summary summary =
                        summarizer.summarize(candidate.toString(), truncate(text));
                if (!summary.relevant() || summary.publishedOn() == null) continue;
                upsert(candidate, summary, hash);
                updated++;
            } catch (RuntimeException error) {
                failed++;
                log.warn("官方政策候选处理失败：host={}", candidate.getHost());
            }
        }
        log.info("官方政策情报刷新完成：inspected={}, updated={}, failed={}",
                inspected, updated, failed);
        return new RefreshResult(inspected, updated, failed);
    }

    private void discoverLinks(URI index, String html, Set<URI> target) {
        Matcher matcher = LINK_PATTERN.matcher(html);
        while (matcher.find() && target.size() < properties.getMaxCandidates() * 3) {
            String anchor = htmlToText(matcher.group(2));
            if (!RELEVANT_TEXT.matcher(anchor).find()) continue;
            try {
                URI candidate = verifiedOfficialUri(index.resolve(matcher.group(1)).toString());
                if (!candidate.equals(index)) target.add(candidate);
            } catch (RuntimeException ignored) {
                // 站外、非 HTTPS 或格式不合法链接不会进入模型。
            }
        }
    }

    private String fetch(URI uri) {
        return fetch(uri, 3);
    }

    private String fetch(URI uri, int redirectsRemaining) {
        verifiedOfficialUri(uri.toString());
        try {
            HttpRequest request = HttpRequest.newBuilder(uri)
                    .timeout(Duration.ofSeconds(18))
                    .header("User-Agent", "Uten-Policy-Monitor/1.0")
                    .GET()
                    .build();
            HttpResponse<byte[]> response = httpClient.send(
                    request, HttpResponse.BodyHandlers.ofByteArray());
            URI finalUri = verifiedOfficialUri(response.uri().toString());
            if (response.statusCode() / 100 == 3 && redirectsRemaining > 0) {
                String location = response.headers().firstValue("Location")
                        .orElseThrow(() -> new IllegalStateException(
                                "官方页面重定向缺少 Location"));
                URI redirected = verifiedOfficialUri(finalUri.resolve(location).toString());
                return fetch(redirected, redirectsRemaining - 1);
            }
            if (response.statusCode() / 100 != 2) {
                throw new IllegalStateException(
                        "官方页面返回 HTTP " + response.statusCode());
            }
            byte[] body = response.body();
            if (body.length > MAX_DOWNLOAD_BYTES) {
                throw new IllegalStateException("官方页面超过采集大小限制");
            }
            String contentType = response.headers()
                    .firstValue("Content-Type").orElse("");
            return decode(body, contentType, finalUri);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("官方页面请求被中断", interrupted);
        } catch (Exception error) {
            if (error instanceof IllegalStateException state) throw state;
            throw new IllegalStateException("官方页面读取失败", error);
        }
    }

    private String decode(byte[] body, String contentType, URI ignoredUri) {
        String probe = new String(body, 0, Math.min(body.length, 4096), StandardCharsets.ISO_8859_1);
        Matcher matcher = CHARSET_PATTERN.matcher(contentType + " " + probe);
        Charset charset = StandardCharsets.UTF_8;
        if (matcher.find()) {
            try {
                charset = Charset.forName(matcher.group(1));
            } catch (Exception ignored) {
                charset = StandardCharsets.UTF_8;
            }
        }
        return charset.decode(ByteBuffer.wrap(body)).toString();
    }

    private URI verifiedOfficialUri(String raw) {
        URI uri = URI.create(raw.strip()).normalize();
        String host = uri.getHost() == null
                ? ""
                : uri.getHost().toLowerCase(Locale.ROOT);
        if (!"https".equalsIgnoreCase(uri.getScheme())
                || !OFFICIAL_HOSTS.contains(host)
                || uri.getUserInfo() != null
                || uri.getFragment() != null) {
            throw new IllegalArgumentException("仅允许预设政府官方 HTTPS 站点");
        }
        return uri;
    }

    private boolean alreadyCurrent(String sourceUrl, String hash) {
        Integer count = jdbc.queryForObject("""
                SELECT COUNT(*) FROM official_policy_briefs
                WHERE source_url = ? AND source_hash = ?
                """, Integer.class, sourceUrl, hash);
        return count != null && count > 0;
    }

    @Transactional
    protected void upsert(
            URI source,
            DeepSeekPolicySummarizer.Summary summary,
            String hash) {
        String audiences;
        try {
            audiences = objectMapper.writeValueAsString(summary.audienceTags());
        } catch (Exception error) {
            throw new IllegalStateException("政策受众序列化失败", error);
        }
        jdbc.update("""
                INSERT INTO official_policy_briefs (
                    title, summary, category, audience_tags, source_name,
                    source_url, source_host, published_on, valid_until,
                    status, source_hash, ai_model, captured_at
                ) VALUES (?, ?, ?, ?::jsonb, ?, ?, ?, ?, ?, 'ACTIVE', ?, ?, now())
                ON CONFLICT (source_url) DO UPDATE SET
                    title = EXCLUDED.title,
                    summary = EXCLUDED.summary,
                    category = EXCLUDED.category,
                    audience_tags = EXCLUDED.audience_tags,
                    source_name = EXCLUDED.source_name,
                    published_on = EXCLUDED.published_on,
                    valid_until = EXCLUDED.valid_until,
                    status = EXCLUDED.status,
                    source_hash = EXCLUDED.source_hash,
                    ai_model = EXCLUDED.ai_model,
                    captured_at = now(),
                    updated_at = now()
                """,
                summary.title(),
                summary.summary(),
                summary.category(),
                audiences,
                sourceName(source.getHost()),
                source.toString(),
                source.getHost().toLowerCase(Locale.ROOT),
                summary.publishedOn(),
                summary.validUntil(),
                hash,
                properties.getModel());
    }

    private static String sourceName(String host) {
        return switch (host.toLowerCase(Locale.ROOT)) {
            case "www.zs.gov.cn", "zs.gov.cn" -> "中山市人民政府";
            case "guangdong.chinatax.gov.cn" -> "国家税务总局广东省税务局";
            case "www.mof.gov.cn", "mof.gov.cn" -> "中华人民共和国财政部";
            case "www.gov.cn", "gov.cn" -> "中国政府网";
            default -> host;
        };
    }

    private static String htmlToText(String html) {
        String withoutScripts = html
                .replaceAll("(?is)<script\\b.*?</script>", " ")
                .replaceAll("(?is)<style\\b.*?</style>", " ")
                .replaceAll("(?is)<[^>]+>", " ");
        return decodeEntities(withoutScripts).replaceAll("\\s+", " ").strip();
    }

    private static String decodeEntities(String value) {
        return value
                .replace("&nbsp;", " ")
                .replace("&#160;", " ")
                .replace("&amp;", "&")
                .replace("&lt;", "<")
                .replace("&gt;", ">")
                .replace("&quot;", "\"")
                .replace("&#39;", "'");
    }

    private static String truncate(String text) {
        return text.length() <= MAX_MODEL_TEXT
                ? text
                : text.substring(0, MAX_MODEL_TEXT);
    }

    private static String sha256(String text) {
        try {
            return HexFormat.of().formatHex(
                    MessageDigest.getInstance("SHA-256")
                            .digest(text.getBytes(StandardCharsets.UTF_8)));
        } catch (Exception error) {
            throw new IllegalStateException("无法计算政策原文摘要", error);
        }
    }

    public record RefreshResult(int inspected, int updated, int failed) {
    }
}
