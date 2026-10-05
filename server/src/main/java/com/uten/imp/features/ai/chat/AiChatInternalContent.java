package com.uten.imp.features.ai.chat;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * ADR-153 one definition of "implementation internals" the assistant never shows: code blocks, shell
 * commands, SQL statements, server addresses, file paths, API paths and internal identifiers (table,
 * function, class and permission names). The answer guard rejects a reply that contains any of them, and
 * the design-document knowledge is stripped of the same patterns before it is indexed, so the model rarely
 * sees them in the first place.
 *
 * <p>Identifiers (snake_case, CONSTANT_CASE, camelCase class names, permission codes) are allowed when the
 * user can already see them: the caller passes the page and tool text as {@code visible}. Blocks, commands,
 * SQL, addresses, paths and API paths are never allowed.
 */
final class AiChatInternalContent {
    static final Pattern CODE_FENCE = Pattern.compile("(?s)(?:```|~~~).*?(?:```|~~~|\\z)");
    /** Shell prompts and commands (Linux, Windows, containers, version control, package managers). */
    static final Pattern SHELL = Pattern.compile("(?im)^\\s*(?:\\$|PS\\s+[A-Z]:\\\\[^>\\n]*>|[A-Z]:\\\\[^>\\n]*>)\\s*[a-z]"
            + "|\\b(?:sudo|ssh|scp|sftp|docker|docker-compose|kubectl|systemctl|journalctl|psql|mysql|pg_dump|pg_restore"
            + "|redis-cli|chmod|chown|crontab|nohup|taskkill|netstat|iptables|powershell|pwsh|cmd\\.exe)\\b"
            + "|\\brm\\s+-[a-z]*[rf]|\\bgit\\s+(?:push|pull|clone|commit|reset|checkout|rebase|merge|log|diff|status|stash)\\b"
            + "|\\b(?:curl|wget)\\s+-{0,2}[a-z]|\\b(?:mvn|npm|npx|pip|pip3|apt|apt-get|yum|brew|gradle)\\s+[a-z]"
            + "|\\bjava\\s+-jar\\b|\\b(?:Get|Set|Invoke|Remove|New|Start|Stop|Restart)-[A-Z][A-Za-z]+\\b"
            // Everyday Linux and Windows commands written with their flags or arguments.
            + "|\\b(?:df|du|ps|kill|lsof|tail|grep|ls|ifconfig|ipconfig|netsh|wmic|reg|shutdown|reboot|pkill|killall|nslookup|tracert"
            + "|traceroute|htop|whoami|uname|top|chmod|chown|ping)\\s+(?:-{1,2}[a-z0-9]|/[a-z?]|:\\d)"
            + "|\\bps\\s+aux\\b|\\bnet\\s+(?:user|stop|start|share|localgroup|use)\\b|\\bservice\\s+\\S+\\s+(?:start|stop|restart|status)\\b"
            + "|\\|\\s*(?:grep|awk|sed|xargs|sort|head|tail|wc)\\b"
            + "|(?:执行|运行|输入|敲入?|在终端里?|在命令行里?)\\s*[a-z][a-z0-9_.-]*\\s+(?:-{1,2}[a-z]|/[a-z]|[a-z]+\\s+\\S)");
    static final Pattern SQL = Pattern.compile("(?i)\\b(?:select\\s+(?:\\*|distinct\\b|count\\s*\\(|[a-z_][\\w.]*(?:\\s*,\\s*[a-z_][\\w.]*)*)\\s+from\\s+[a-z_]"
            // Any SELECT with an aggregate or a FROM ... WHERE/GROUP/ORDER/JOIN, whatever the identifiers (Chinese ones too).
            + "|select\\b[^\\n]{0,80}?\\b(?:sum|count|avg|max|min)\\s*\\([^\\n]{0,120}?\\bfrom\\b"
            + "|select\\b[^\\n]{1,160}?\\bfrom\\s+\\S+[^\\n]{0,80}?\\b(?:where|group\\s+by|order\\s+by|join|having|limit)\\b"
            + "|with\\s+\\w+\\s+as\\s*\\(\\s*select\\b"
            + "|insert\\s+into\\s+[a-z_]|update\\s+[a-z_][\\w.]*\\s+set\\s+[a-z_]|delete\\s+from\\s+[a-z_]"
            + "|drop\\s+(?:table|database|schema|function|view|trigger|index)\\b|alter\\s+(?:table|database)\\s+[a-z_]"
            + "|create\\s+(?:or\\s+replace\\s+)?(?:table|index|function|trigger|view|database)\\b"
            + "|truncate\\s+(?:table\\s+)?[a-z_]|grant\\s+[a-z]+\\s+on\\b)");
    static final Pattern ADDRESS = Pattern.compile("(?i)(?<![\\w.])(?:\\d{1,3}\\.){3}\\d{1,3}(?![\\w.])|\\blocalhost\\b"
            + "|(?<![\\w.])(?=[a-z0-9.-]*[a-z])[a-z0-9-]+(?:\\.[a-z0-9-]+)+:\\d{2,5}(?![\\d])"
            // Ports written in words, internal host names and IPv6 addresses.
            + "|端口\\s*(?:号)?\\s*(?:是|为|:|：)?\\s*\\d{2,5}(?!\\d)|(?<![\\d.])\\d{2,5}\\s*端口|\\bport\\s*(?:number\\s*)?(?:is\\s*)?:?\\s*\\d{4,5}\\b"
            + "|\\b[a-z0-9-]+(?:\\.[a-z0-9-]+)*\\.(?:local|internal|lan|corp|intranet|localdomain)\\b"
            + "|(?<![\\w:])(?=[0-9a-f:]*[a-f])(?:[0-9a-f]{1,4}:){2,7}[0-9a-f]{1,4}(?![\\w:])|(?<![\\w:])[0-9a-f]{1,4}::(?:[0-9a-f]{1,4})?(?![\\w:])");
    /** Code statements in any language: VBA, Python, JavaScript, regular expressions. */
    static final Pattern CODE_LINE = Pattern.compile("\\bEnd\\s+Sub\\b|\\bSub\\s+\\S+\\s*\\(\\s*\\)|\\bRange\\s*\\(\\s*\"|\\bDim\\s+\\w+\\s+As\\b"
            + "|\\bfor\\s+\\w+\\s+in\\s+(?:range\\s*\\(|\\w+\\s*:)|\\bdef\\s+\\w+\\s*\\(|\\bfunction\\s+\\w*\\s*\\(|\\bconsole\\.log\\b|\\bprint\\s*\\("
            + "|\\bif\\s*\\(.{1,60}\\)\\s*\\{|=>\\s*\\{|\\breturn\\s+[\\w.]+\\s*;|\\b(?:public|private|static)\\s+(?:void|int|String)\\b"
            + "|\\^[^\\s^$]{1,40}\\$|\\\\[dDwWsS](?:\\{\\d+(?:,\\d*)?\\}|[+*?])|\\[\\^?[^\\]\\s]{1,20}\\](?:\\{\\d|[+*])");
    /** Database names and schemas. */
    static final Pattern DATABASE = Pattern.compile("(?i)\\bschema\\b|数据库(?:名|名称|名字|账号|用户名|地址|主机|实例)");
    /**
     * The assistant's own instructions echoed back: intent names, source ids, the untrusted-data markers or a
     * paraphrase of the prompt's rules.
     */
    static final Pattern PROMPT_ECHO = Pattern.compile("(?:只能|必须)(?:选|选择)(?:一个|一种)意图|意图(?:有|包括|分为)[:：]|页面状态、页面帮助"
            + "|系统提示词|我的(?:系统)?(?:指令|提示词)(?:是|如下)|我收到的(?:指令|说明|规则)(?:是|如下)|\\bPAGE_(?:STATE|HELP)\\b|\\busedSources\\b"
            + "|\\bknowledge\\.(?:doc|[A-Z])|\\bconversation\\.history\\b|\\bpage\\.(?:legend|tables|fields|review|actions)\\b"
            + "|\\buntrusted\\b|UNTRUSTED_DOCUMENT|\\bOUT_OF_SCOPE\\b");
    /** A field written as code: "status=1", "qty=5". */
    static final Pattern FIELD_ASSIGN = Pattern.compile("(?<![\\w])[a-z][a-zA-Z_]{2,}=\\S");
    /** A class name with a code suffix ("StockService", "AnswerGuard"); brand names stay. */
    static final Pattern CLASS_SUFFIX = Pattern.compile("(?<![\\w])[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)*(?:Service|Controller|Handler|Repository|Impl"
            + "|Dto|Entity|Mapper|Utils?|Config|Exception|Listener|Processor|Resolver|Validator|Gateway|Dao|Renderer|Chunker"
            + "|Worker|Job)(?![\\w])");
    static final Pattern PATH = Pattern.compile("(?i)\\b[a-z]:\\\\\\S*"
            + "|(?<![\\w.])/(?:etc|var|home|usr|opt|root|tmp|srv|mnt|proc|bin|sbin|data|app|deploy|backup)/\\S*"
            + "|(?<![\\w./])(?:\\.\\./|\\./)\\S+"
            + "|(?<![\\w/])(?:lib|server|src|docs|deploy|scripts|test|web|android|ios|assets|target|logs)/[\\w\\-./\\p{IsHan}()]+"
            + "|(?<![\\w\\-])[\\w\\-\\p{IsHan}]+\\.(?:java|dart|py|sh|bat|ps1|yml|yaml|properties|env|conf|cfg|ini|toml|log|jar|war"
            + "|sql|js|ts|kt|xml|gradle|md|arb)\\b");
    static final Pattern API_PATH = Pattern.compile("(?<![\\w])/api/[\\w/{}\\-.:?=&]*");
    /** An application route ("/production/workshop-tasks"): users know pages by their titles. */
    static final Pattern ROUTE = Pattern.compile("(?<![\\w.])/[a-z][a-z0-9-]*(?:/[a-z0-9:_{}-]+)+");
    static final Pattern SNAKE =Pattern.compile("(?<![\\w])[a-z][a-z0-9]*(?:_[a-z0-9]+)+(?![\\w])");
    static final Pattern CONSTANT = Pattern.compile("(?<![\\w])[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+(?![\\w])");
    static final Pattern PERMISSION_CODE = Pattern.compile("(?<![\\w:/])[a-z][a-z_]*:[a-z_]+(?::[a-z_]+)*(?![\\w:])");
    static final Pattern CLASS_NAME = Pattern.compile("(?<![\\w])(?:[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+){2,}|[a-z]+(?:[A-Z][a-z0-9]+){2,})(?![\\w])");
    /** A field name such as "weightKg" (documents only: a product name like "iPhone" in a reply is not flagged). */
    static final Pattern FIELD_NAME = Pattern.compile("(?<![\\w])[a-z]{2,}(?:[A-Z][a-z0-9]+)+(?![\\w])");
    static final Pattern CALL = Pattern.compile("(?<![\\w])[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)+\\s*\\("
            + "|(?<![\\w])[A-Za-z_][A-Za-z0-9_]{2,}\\(\\s*\\)");

    private AiChatInternalContent() {}

    /**
     * Problem kinds found in {@code text} ("CODE_BLOCK", "SHELL:docker", ...), in order of appearance kind.
     *
     * @param visible text the user can already see (page snapshot, tool facts, the question); identifiers
     *                found there are not internal to this user
     */
    static List<String> problems(String text, String visible) {
        if (text == null || text.isBlank()) return List.of();
        Set<String> found = new LinkedHashSet<>();
        if (CODE_FENCE.matcher(text).find()) found.add("CODE_BLOCK");
        first(SHELL, text).ifPresent(hit -> found.add("SHELL:" + hit));
        first(SQL, text).ifPresent(hit -> found.add("SQL"));
        first(CODE_LINE, text).ifPresent(hit -> found.add("CODE"));
        first(DATABASE, text).ifPresent(hit -> found.add("DATABASE"));
        first(PROMPT_ECHO, text).ifPresent(hit -> found.add("PROMPT_ECHO"));
        first(ADDRESS, text).ifPresent(hit -> found.add("ADDRESS"));
        first(PATH, text).ifPresent(hit -> found.add("PATH"));
        first(API_PATH, text).ifPresent(hit -> found.add("API_PATH"));
        String lowerVisible = visible == null ? "" : visible.toLowerCase(Locale.ROOT);
        for (var entry : List.of(java.util.Map.entry("TABLE_OR_FIELD", SNAKE), java.util.Map.entry("CONSTANT", CONSTANT),
                java.util.Map.entry("PERMISSION_CODE", PERMISSION_CODE), java.util.Map.entry("CLASS", CLASS_NAME),
                java.util.Map.entry("CLASS", CLASS_SUFFIX), java.util.Map.entry("TABLE_OR_FIELD", FIELD_NAME),
                java.util.Map.entry("TABLE_OR_FIELD", FIELD_ASSIGN), java.util.Map.entry("CALL", CALL))) {
            Matcher matcher = entry.getValue().matcher(text);
            while (matcher.find()) {
                if (!lowerVisible.contains(matcher.group().toLowerCase(Locale.ROOT).replaceAll("\\s*\\($", ""))) {
                    found.add(entry.getKey());
                    break;
                }
            }
        }
        return List.copyOf(found);
    }

    private static java.util.Optional<String> first(Pattern pattern, String text) {
        Matcher matcher = pattern.matcher(text);
        if (!matcher.find()) return java.util.Optional.empty();
        String hit = matcher.group().strip();
        return java.util.Optional.of(hit.length() > 20 ? hit.substring(0, 20) : hit);
    }

    /**
     * Design-document text with every internal pattern removed (ADR-153): code blocks, inline code that
     * names an identifier, links, commands, SQL lines, addresses, paths, API paths, identifiers and
     * migration numbers. Plain business words in inline code are kept without the backticks.
     */
    static String strip(String markdown) {
        if (markdown == null || markdown.isBlank()) return "";
        String text = CODE_FENCE.matcher(markdown).replaceAll("\n");
        text = text.replaceAll("(?s)<!--.*?-->", "");
        // Links keep their text; images go.
        text = text.replaceAll("!\\[[^\\]\\n]*\\]\\([^)\\n]*\\)", "");
        text = text.replaceAll("\\[([^\\]\\n]{1,200})\\]\\([^)\\n]{0,2000}\\)", "$1");
        text = text.replaceAll("(?i)(?:[a-z][a-z0-9+.-]{1,15}://|www\\.)[^\\s)\uFF09\\]]*", "");
        Matcher inline = Pattern.compile("`([^`\\n]{0,200})`").matcher(text);
        StringBuilder out = new StringBuilder();
        while (inline.find()) {
            String code = inline.group(1).strip();
            inline.appendReplacement(out, Matcher.quoteReplacement(identifierLike(code) ? "" : code));
        }
        inline.appendTail(out);
        List<String> lines = new ArrayList<>();
        for (String line : out.toString().split("\n", -1)) {
            // A line that is a command or a statement is dropped whole, not left half-readable.
            if (SHELL.matcher(line).find() || SQL.matcher(line).find() || CODE_LINE.matcher(line).find()) continue;
            lines.add(line);
        }
        text = String.join("\n", lines);
        for (Pattern pattern : List.of(API_PATH, PATH, ROUTE, ADDRESS, CALL, SNAKE, CONSTANT, PERMISSION_CODE, CLASS_NAME,
                CLASS_SUFFIX, FIELD_NAME, FIELD_ASSIGN)) {
            text = pattern.matcher(text).replaceAll("");
        }
        text = text.replaceAll("(?<![\\w-])V\\d{2,4}(?![\\w])", "");
        // Leftovers of removed words: empty brackets, doubled separators and spaces.
        text = text.replaceAll("[(\uFF08]\\s*[,\uFF0C、/;；]*\\s*[)\uFF09]", "")
                .replaceAll("([、,\uFF0C/])\\s*(?:[、,\uFF0C/]\\s*)+", "$1")
                .replaceAll("[ \\t\u00A0]{2,}", " ")
                .replaceAll(" *\n", "\n")
                .replaceAll("\n{3,}", "\n\n");
        return text.strip();
    }

    /** Inline code that is an identifier, path, expression or code word rather than a business word. */
    static boolean identifierLike(String code) {
        if (code.isEmpty()) return true;
        if (code.codePoints().anyMatch(Character::isIdeographic)) {
            // Business words written as code ("未称", "≈ 25 kg") stay; anything with code punctuation goes.
            return code.matches(".*[_{}\\[\\]<>=;$\\\\].*") || API_PATH.matcher(code).find() || PATH.matcher(code).find();
        }
        if (code.matches(".*[_./:(){}\\[\\]<>=;$\\\\@#].*")) return true;
        if (CLASS_NAME.matcher(code).find()) return true;
        // A lone lowercase word or several words (a parameter, command or keyword) is code; an all-caps short
        // word ("REVIEW") or a number with a unit stays.
        if (code.matches("[a-z][a-z0-9 -]*")) return true;
        return false;
    }
}
