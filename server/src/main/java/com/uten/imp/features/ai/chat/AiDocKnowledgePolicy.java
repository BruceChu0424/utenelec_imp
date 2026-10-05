package com.uten.imp.features.ai.chat;

import org.springframework.util.AntPathMatcher;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * ADR-153 which project documents the assistant may cite. Only the platform's own design documents
 * (decision records, page documents, business chains, module summaries without code-level content, and
 * the two business-counting guidelines) are packaged and indexed; documents about deployment, servers,
 * security internals, sessions, the AI assistant itself, project governance and data migration are not.
 * Source code is never a knowledge source.
 *
 * <p>The same include/exclude lists are written in {@code server/pom.xml} (the resource block with target
 * path {@value #RESOURCE_ROOT}); {@code AiDocKnowledgePolicyTest} keeps the two identical. The index applies
 * the lists again, so a stray packaged file is still never cited.
 */
final class AiDocKnowledgePolicy {
    static final String RESOURCE_ROOT = "ai-knowledge";

    static final List<String> INCLUDES = List.of(
            "99-决策记录-ADR/ADR-*.md",
            "03-页面/*.md",
            "07-业务链路/*.md",
            "98-模块总结/*.md",
            "00-项目准则/13-适老化UX基线.md",
            "00-项目准则/14-徽章与计数口径.md");

    /**
     * Technology, security, session, deployment, release, audit-infrastructure and AI-assistant decisions,
     * system administration pages and code-level summaries.
     */
    static final List<String> EXCLUDES = List.of(
            "99-决策记录-ADR/ADR-001-*.md", "99-决策记录-ADR/ADR-002-*.md", "99-决策记录-ADR/ADR-003-*.md",
            "99-决策记录-ADR/ADR-004-*.md", "99-决策记录-ADR/ADR-005-*.md", "99-决策记录-ADR/ADR-006-*.md",
            "99-决策记录-ADR/ADR-007-*.md", "99-决策记录-ADR/ADR-008-*.md", "99-决策记录-ADR/ADR-009-*.md",
            "99-决策记录-ADR/ADR-013-*.md", "99-决策记录-ADR/ADR-014-*.md", "99-决策记录-ADR/ADR-015-*.md",
            "99-决策记录-ADR/ADR-016-*.md", "99-决策记录-ADR/ADR-017-*.md", "99-决策记录-ADR/ADR-022-*.md",
            "99-决策记录-ADR/ADR-031-*.md", "99-决策记录-ADR/ADR-037-*.md", "99-决策记录-ADR/ADR-044-*.md",
            "99-决策记录-ADR/ADR-045-*.md", "99-决策记录-ADR/ADR-060-*.md", "99-决策记录-ADR/ADR-061-*.md",
            "99-决策记录-ADR/ADR-067-*.md", "99-决策记录-ADR/ADR-074-*.md", "99-决策记录-ADR/ADR-105-*.md",
            "99-决策记录-ADR/ADR-106-*.md", "99-决策记录-ADR/ADR-107-*.md", "99-决策记录-ADR/ADR-108-*.md",
            "99-决策记录-ADR/ADR-109-*.md", "99-决策记录-ADR/ADR-110-*.md", "99-决策记录-ADR/ADR-133-*.md",
            "99-决策记录-ADR/ADR-140-*.md", "99-决策记录-ADR/ADR-141-*.md", "99-决策记录-ADR/ADR-150-*.md",
            "99-决策记录-ADR/ADR-152-*.md", "99-决策记录-ADR/ADR-153-*.md",
            "03-页面/系统设置页.md", "03-页面/AI服务设置页.md", "03-页面/权限管理页.md", "03-页面/页面总览.md",
            "03-页面/登录页.md", "03-页面/审计日志页.md", "03-页面/模拟身份(切换人).md",
            "07-业务链路/02-数据库设计-*.md", "07-业务链路/03-续作指引.md",
            "07-业务链路/2026-09-07-履约事务锁顺序与来源漂移处理.md",
            "98-模块总结/*代码总结.md");

    /**
     * Sections about implementation rather than business rules are dropped with their subsections:
     * security, sessions, deployment, migration, tests, code, interfaces, database, performance, peer
     * research and references.
     */
    static final Pattern DROPPED_SECTION = Pattern.compile("(?i)安全(?!库存|量)|认证|鉴权|密码|口令|令牌|token|jwt|会话|加密|密钥"
            + "|\\bhmac\\b|\\bdns\\b|\\bvpn\\b|\\bhttps?\\b|\\btls\\b|\\bwaf\\b|反向代理|可信代理|域名|内网|公网|网络|远程访问|回执密钥"
            + "|变更记录|更新记录|修订记录|版本记录|变更历史|更新日志|修订历史|变更日志"
            + "|部署|发布链|发版|运维|服务器|迁移|退役|测试|验证记录|验收记录|代码|函数|技术方案|实现细节|实现要点|实现备注|接口|端点|\\bapi\\b"
            + "|数据库|表结构|数据模型|索引|触发器|\\bsql\\b|性能|同行|调研|业界|参考系统|借鉴|附录|文件清单|改动清单|变更清单|实施记录"
            // Superseded designs: only the current rule is knowledge.
            + "|设计快照|历史参考|历史口径|旧口径|已废弃|已取代|已退役"
            + "|(?:^|[、.\\s])参考(?:资料|链接|文献|出处)?\\s*$"
            // Background, the old behaviour, rejected alternatives and reviews describe what is NOT the rule now.
            + "|^[\\s\\d.、一二三四五六七八九十零之]*(?:背景|问题|现状|改造前|备选|方案对比|被否决|未采纳|验证|验收|评审|风险|已知遗留|遗留)");
    /** Decision-record metadata lines (status, supersedes, related): references, not rules. */
    static final Pattern METADATA_LINE = Pattern.compile(
            "^\\s*[-*]\\s*\\*\\*(?:状态|取代|相关|日期|关联|作者|决策者|上下文|参与者|编号|范围)\\*\\*.*$"
                    + "|^\\s*>\\s*(?:\\*\\*)?(?:状态|最近更新|最后更新|更新日期|更新时间|更新|变更|版本|修订|日期|作者|相关|关联|取代|被取代)"
                    + "(?:\\*\\*)?\\s*[:：].*$");

    /**
     * ADR-153 revision, fail-closed second layer: whatever document is whitelisted (now or later), a sentence that
     * names security or deployment internals (tokens, signing keys, encryption, network and addressing, primary or
     * standby database, ports) is never indexed or sent. The document lists decide what is read; this decides what
     * of it may leave.
     */
    static final Pattern SECURITY_TEXT = Pattern.compile("(?i)\\bjwt\\b|\\bhmac\\b|pgcrypto|refresh\\s*token|access\\s*token|\\btoken\\b"
            + "|\\bdns\\b|split-horizon|\\bvpn\\b|\\bhttps?\\b|\\btls\\b|\\bssl\\b|\\bwaf\\b|可信端点|可信代理|反向代理|内网|公网|域名|证书链"
            + "|签名密钥|加密密钥|密钥|私钥|令牌|主库(?!存)|备库(?!存)|数据库连接|连接串|\\b(?:808\\d|5432|5433|6379|3306|9090)\\b"
            + "|\\d{2,5}\\s*端口|端口\\s*\\d{2,5}|端口号|\\bip\\s*地址|\\bip\\b|\\bschema\\b|数据库(?:名|名称|名字|账号|用户名|地址|主机|实例)"
            // Storage types say how the database is built, not what the business rule is.
            + "|\\b(?:NUMERIC|DECIMAL|VARCHAR|BIGINT|SMALLINT|JSONB|TIMESTAMPTZ|BIGSERIAL)\\b");

    /** The text without the sentences that name security or deployment internals (see {@link #SECURITY_TEXT}). */
    static String withoutSecurityText(String text) {
        if (text == null || text.isEmpty() || !SECURITY_TEXT.matcher(text).find()) return text;
        StringBuilder out = new StringBuilder();
        for (String line : text.split("\n", -1)) {
            StringBuilder kept = new StringBuilder();
            for (String sentence : line.split("(?<=[。；！？;])")) {
                if (!SECURITY_TEXT.matcher(sentence).find()) kept.append(sentence);
            }
            String value = kept.toString();
            if (!value.isBlank() || line.isBlank()) out.append(value).append('\n');
        }
        return out.toString().replaceAll("\n{3,}", "\n\n").strip();
    }

    private static final AntPathMatcher MATCHER = new AntPathMatcher();

    /**
     * Documents of system administration pages that only administrators may read (ADMIN domain, which only
     * super administrators hold): what the page shows, never how the system is deployed or secured.
     */
    static final List<String> ADMIN_ONLY = List.of("03-页面/服务器状态页.md");

    /** True when a section with this heading (or under it) is implementation detail, not a business rule. */
    static boolean droppedSection(String heading) {
        return heading != null && DROPPED_SECTION.matcher(heading).find();
    }

    /** Self-service documents: reimbursement, leave, the user's own pages and settings (visible to every chat user). */
    private static final Pattern SELF_SERVICE = Pattern.compile("报销|请假|我的|个人中心|个人信息|设置页|自助");

    /** Business domains named by a document's path and title; none means a platform-wide document. */
    private static final Map<String, Pattern> DOMAINS = Map.ofEntries(
            Map.entry("SALES", Pattern.compile("销售|报价|客户|出货|发货|应收|收款|退货|缺货仲裁|预留")),
            Map.entry("PURCHASE", Pattern.compile("采购|供应商|到货|应付")),
            Map.entry("WAREHOUSE", Pattern.compile("仓库|库存|入库|出库|出入库|盘点|称重|重量|货架|库位|不良品|料仓|待检")),
            Map.entry("PRODUCTION", Pattern.compile("生产|车间|报工|排产|物料|BOM|领料|日报|产量|产成品|流水线|计划|工序|直送|备料|超产|补产|调度")),
            Map.entry("QUALITY", Pattern.compile("品质|质检|检验|IQC|不良|待检")),
            Map.entry("SUBCONTRACT", Pattern.compile("委外|外协")),
            Map.entry("FINANCE", Pattern.compile("财务|钱流|成本|资金|收款|付款|应收|应付|汇率|币种|资产|待摊|金额|账户|核价|过账|往来")),
            Map.entry("HR", Pattern.compile("人事|员工档案|花名册|入职|离职|工资|薪|转正|组织|岗位|HR")),
            Map.entry("RD", Pattern.compile("研发|工程研发|ECN")),
            Map.entry("ADMIN", Pattern.compile("权限|授权|审计")));

    private AiDocKnowledgePolicy() {}

    /** True when the document at {@code relativePath} (under docs/, '/'-separated) may be indexed. */
    static boolean included(String relativePath) {
        if (relativePath == null || relativePath.contains("..")) return false;
        return INCLUDES.stream().anyMatch(pattern -> MATCHER.match(pattern, relativePath))
                && EXCLUDES.stream().noneMatch(pattern -> MATCHER.match(pattern, relativePath));
    }

    /**
     * Domains of a document, from its file name and title. A document naming no business domain (badges,
     * accessibility, workbench, tables) is visible to everyone who may use the assistant.
     */
    static Set<String> domains(String relativePath, String title) {
        if (ADMIN_ONLY.contains(relativePath)) return Set.of("ADMIN");
        String name = relativePath.substring(relativePath.lastIndexOf('/') + 1) + " " + (title == null ? "" : title);
        // Every employee's own matters (reimbursement, leave, "my" pages, settings) are explained to every chat user.
        if (SELF_SERVICE.matcher(name).find()) return Set.of();
        Set<String> domains = new LinkedHashSet<>();
        DOMAINS.forEach((domain, words) -> {
            if (words.matcher(name).find()) domains.add(domain);
        });
        return Set.copyOf(domains);
    }
}
