package com.uten.imp.features.ai.provider;

import java.net.Inet4Address;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.URI;
import java.net.URISyntaxException;
import java.net.UnknownHostException;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * AI 服务接口地址的防 SSRF 规则(ADR-133)。保存配置时做静态检查, 每次真正发请求前再解析 DNS
 * 逐个地址检查({@link #checkResolved}); 客户端禁止跟随跳转(3xx 当错误)。
 *
 * <ul>
 *   <li>境内/境外服务商: 只允许 https, 解析出的每个地址都必须是公网地址。</li>
 *   <li>本机部署(LOCAL): 地址必须是本机回环或内网; 明文 http 只允许<b>字面</b>回环地址
 *       (127.0.0.0/8、::1), 运维开启 {@code uten.ai.allow-lan-http} 后才允许 http 访问内网
 *       (RFC1918、fc00::/7)。</li>
 *   <li>一律拒绝: 带用户名密码、查询串、片段; 路径含 {@code ..}/{@code .} 段、{@code %}、{@code \}、{@code ;};
 *       0.0.0.0/8、169.254/16(云元数据)、100.64.0.0/10(含阿里云元数据 100.100.100.200)、组播与保留段、
 *       fe80::/10、fec0::/10、64:ff9b::/96(NAT64)、以上地址的 ::ffff: 映射形式; 以 metadata 开头的主机名;
 *       纯数字等非标准写法的主机。</li>
 * </ul>
 * 残余风险: 请求前的 DNS 检查与 HTTP 客户端自己的解析之间存在极短的时间差(DNS 重绑定),
 * 由「只有超管能配置地址」与禁止跳转兜底, 见 ADR-133。
 */
public final class AiEndpointPolicy {

    private static final int MAX_URL_LENGTH = 512;
    private static final Pattern IPV4_LITERAL = Pattern.compile(
            "^(25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)(\\.(25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)){3}$");
    private static final Pattern DNS_LABEL = Pattern.compile("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$");
    private static final Pattern HAS_LETTER = Pattern.compile(".*[a-z].*");

    private AiEndpointPolicy() {
    }

    /** 地址分类。 */
    public enum AddressClass { LOOPBACK, PRIVATE, PUBLIC, DENIED }

    /** DNS 解析(测试可替换)。 */
    @FunctionalInterface
    public interface HostResolver {
        InetAddress[] resolve(String host) throws UnknownHostException;

        HostResolver SYSTEM = InetAddress::getAllByName;
    }

    /**
     * 解析后的接口地址。
     *
     * @param scheme     小写 http/https
     * @param host       小写主机(IPv6 不带方括号)
     * @param literal    主机是字面 IP
     * @param normalized 规范化的「协议://主机[:端口]路径」(去掉默认端口与末尾斜杠), 用于拼接接口与比较是否改了地址
     */
    public record Endpoint(String scheme, String host, boolean literal, int port, String path, String normalized) {
    }

    /** 违反规则; 消息是给管理员看的中文。 */
    public static final class PolicyViolation extends RuntimeException {
        public PolicyViolation(String message) {
            super(message);
        }
    }

    /** 只做语法检查并规范化(不查 DNS)。 */
    public static Endpoint parse(String raw) {
        if (raw == null || raw.isBlank()) {
            throw new PolicyViolation("请填写接口地址");
        }
        String value = raw.trim();
        if (value.length() > MAX_URL_LENGTH) {
            throw new PolicyViolation("接口地址太长");
        }
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c <= 0x20 || c == 0x7f || c == '\\') {
                throw new PolicyViolation("接口地址里不能有空格、反斜杠或控制字符");
            }
        }
        URI uri;
        try {
            uri = new URI(value);
        } catch (URISyntaxException e) {
            throw new PolicyViolation("接口地址格式不对, 例如 https://api.deepseek.com");
        }
        String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase(Locale.ROOT);
        if (!scheme.equals("https") && !scheme.equals("http")) {
            throw new PolicyViolation("接口地址必须以 https:// 开头(本机部署可以用 http://127.0.0.1)");
        }
        if (uri.isOpaque() || uri.getRawAuthority() == null) {
            throw new PolicyViolation("接口地址格式不对, 例如 https://api.deepseek.com");
        }
        if (uri.getRawUserInfo() != null || uri.getRawAuthority().contains("@")) {
            throw new PolicyViolation("接口地址里不能带用户名或密码");
        }
        if (uri.getRawQuery() != null || uri.getRawFragment() != null) {
            throw new PolicyViolation("接口地址里不能带 ? 或 # 后面的参数");
        }
        String rawHost = uri.getHost();
        if (rawHost == null || rawHost.isBlank() || rawHost.contains("%")) {
            throw new PolicyViolation("接口地址里的主机名不对");
        }
        String host = rawHost.toLowerCase(Locale.ROOT);
        boolean literal;
        if (host.startsWith("[") && host.endsWith("]")) {
            host = host.substring(1, host.length() - 1);
            literal = true;
            parseLiteral(host);
        } else if (IPV4_LITERAL.matcher(host).matches()) {
            literal = true;
        } else {
            literal = false;
            requireDnsName(host);
        }
        int port = uri.getPort();
        if (port == 0 || port > 65535) {
            throw new PolicyViolation("接口地址里的端口不对");
        }
        String path = uri.getRawPath() == null ? "" : uri.getRawPath();
        if (path.contains("%") || path.contains(";")) {
            throw new PolicyViolation("接口地址的路径里不能有 % 或 ;");
        }
        for (String segment : path.split("/", -1)) {
            if (segment.equals(".") || segment.equals("..")) {
                throw new PolicyViolation("接口地址的路径里不能有 . 或 ..");
            }
        }
        String trimmedPath = path.replaceAll("/+$", "");
        int defaultPort = scheme.equals("https") ? 443 : 80;
        String hostPart = host.contains(":") ? "[" + host + "]" : host;
        String normalized = scheme + "://" + hostPart
                + (port == -1 || port == defaultPort ? "" : ":" + port) + trimmedPath;
        return new Endpoint(scheme, host, literal, port == -1 ? defaultPort : port, trimmedPath, normalized);
    }

    /** 规范化地址(解析失败返回空), 用于比较「是否改了接口地址」。 */
    public static String normalizeOrNull(String raw) {
        try {
            return parse(raw).normalized();
        } catch (PolicyViolation e) {
            return null;
        }
    }

    /**
     * 保存配置时的检查: 语法 + 协议与区域规则 + 字面地址分类(主机名要到调用时解析)。
     */
    public static Endpoint validateConfigured(String raw, AiRegion region, boolean allowLanHttp) {
        Endpoint endpoint = parse(raw);
        if (endpoint.host().startsWith("metadata")) {
            throw new PolicyViolation("接口地址不能指向云服务器的元数据服务");
        }
        if (endpoint.scheme().equals("http")) {
            if (region != AiRegion.LOCAL) {
                throw new PolicyViolation("只有本机部署的服务可以用 http, 其他服务请用 https");
            }
            if (!endpoint.literal() && !allowLanHttp) {
                throw new PolicyViolation("本机部署用 http 时请填写 127.0.0.1(不要写 localhost 或其他主机名)");
            }
        }
        if (endpoint.literal()) {
            checkAddress(literalAddress(endpoint.host()), endpoint, region, allowLanHttp);
        }
        return endpoint;
    }

    /** 调用前的检查: 解析 DNS, 每一个地址都必须符合规则。 */
    public static void checkResolved(Endpoint endpoint, AiRegion region, boolean allowLanHttp,
                                     HostResolver resolver) {
        validateConfigured(endpoint.normalized(), region, allowLanHttp);
        if (endpoint.literal()) {
            return;
        }
        InetAddress[] addresses;
        try {
            addresses = resolver.resolve(endpoint.host());
        } catch (UnknownHostException e) {
            throw new UnresolvableHost("找不到接口地址里的主机(域名解析失败), 请检查地址或服务器网络");
        }
        if (addresses == null || addresses.length == 0) {
            throw new UnresolvableHost("找不到接口地址里的主机(域名解析失败), 请检查地址或服务器网络");
        }
        for (InetAddress address : addresses) {
            checkAddress(address, endpoint, region, allowLanHttp);
        }
    }

    /** 域名解析失败(属于网络问题, 不是配置违规)。 */
    public static final class UnresolvableHost extends RuntimeException {
        public UnresolvableHost(String message) {
            super(message);
        }
    }

    private static void checkAddress(InetAddress address, Endpoint endpoint, AiRegion region, boolean allowLanHttp) {
        AddressClass type = classify(address);
        if (type == AddressClass.DENIED) {
            throw new PolicyViolation("接口地址指向了不允许访问的地址(元数据、保留或特殊用途地址)");
        }
        if (region == AiRegion.LOCAL) {
            if (type == AddressClass.PUBLIC) {
                throw new PolicyViolation("本机部署的服务必须是本机或内网地址; 公网服务请选对应服务商或「自定义」");
            }
            if (endpoint.scheme().equals("http")) {
                if (type == AddressClass.LOOPBACK && !endpoint.literal()) {
                    throw new PolicyViolation("本机部署用 http 时请填写 127.0.0.1(不要写 localhost 或其他主机名)");
                }
                if (type == AddressClass.PRIVATE && !allowLanHttp) {
                    throw new PolicyViolation("明文 http 只允许本机地址 127.0.0.1; 内网明文访问需要运维在服务器配置里开启");
                }
            }
            return;
        }
        if (type != AddressClass.PUBLIC) {
            throw new PolicyViolation("接口地址指向了本机或内网; 本机或内网部署请把区域选为「本机部署」");
        }
    }

    private static InetAddress literalAddress(String host) {
        return parseLiteral(host);
    }

    private static InetAddress parseLiteral(String host) {
        try {
            if (host.contains(":")) {
                if (!host.matches("^[0-9a-f:.]+$")) {
                    throw new PolicyViolation("接口地址里的主机名不对");
                }
                return InetAddress.getByName(host);
            }
            if (!IPV4_LITERAL.matcher(host).matches()) {
                throw new PolicyViolation("接口地址里的主机名不对");
            }
            return InetAddress.getByName(host);
        } catch (UnknownHostException e) {
            throw new PolicyViolation("接口地址里的主机名不对");
        }
    }

    private static void requireDnsName(String host) {
        if (host.length() > 253 || host.endsWith(".")) {
            throw new PolicyViolation("接口地址里的主机名不对");
        }
        String[] labels = host.split("\\.", -1);
        for (String label : labels) {
            if (!DNS_LABEL.matcher(label).matches()) {
                throw new PolicyViolation("接口地址里的主机名不对");
            }
        }
        if (!HAS_LETTER.matcher(labels[labels.length - 1]).matches()) {
            throw new PolicyViolation("接口地址里的主机名不对(IP 地址请写成 1.2.3.4 的标准形式)");
        }
        if (labels[0].startsWith("metadata")) {
            throw new PolicyViolation("接口地址不能指向云服务器的元数据服务");
        }
    }

    /** 地址分类; IPv4 映射/兼容/6to4 形式按内嵌的 IPv4 判断。 */
    public static AddressClass classify(InetAddress address) {
        byte[] b = address.getAddress();
        if (address instanceof Inet4Address) {
            return classifyV4(b, 0);
        }
        if (!(address instanceof Inet6Address) || b.length != 16) {
            return AddressClass.DENIED;
        }
        boolean firstTenZero = true;
        for (int i = 0; i < 10; i++) {
            if (b[i] != 0) {
                firstTenZero = false;
                break;
            }
        }
        if (firstTenZero && (b[10] & 0xff) == 0xff && (b[11] & 0xff) == 0xff) {
            return classifyV4(b, 12);
        }
        if (firstTenZero && b[10] == 0 && b[11] == 0) {
            boolean loopback = b[15] == 1 && b[12] == 0 && b[13] == 0 && b[14] == 0;
            if (loopback) {
                return AddressClass.LOOPBACK;
            }
            // :: 与已废弃的 IPv4 兼容地址。
            return AddressClass.DENIED;
        }
        int b0 = b[0] & 0xff;
        int b1 = b[1] & 0xff;
        if (b0 == 0x00 && b1 == 0x64 && (b[2] & 0xff) == 0xff && (b[3] & 0xff) == 0x9b) {
            // 64:ff9b::/96 与 64:ff9b:1::/48(NAT64)。
            return AddressClass.DENIED;
        }
        if (b0 == 0xfe && (b1 & 0xc0) == 0x80) {
            return AddressClass.DENIED; // fe80::/10 链路本地
        }
        if (b0 == 0xfe && (b1 & 0xc0) == 0xc0) {
            return AddressClass.DENIED; // fec0::/10 站点本地(已废弃)
        }
        if (b0 == 0xff) {
            return AddressClass.DENIED; // 组播
        }
        if (b0 == 0x20 && b1 == 0x02) {
            // 6to4: 2002:AABB:CCDD::/48 内嵌 IPv4。
            AddressClass embedded = classifyV4(b, 2);
            return embedded == AddressClass.PUBLIC ? AddressClass.PUBLIC : AddressClass.DENIED;
        }
        if (b0 == 0x20 && b1 == 0x01 && b[2] == 0 && b[3] == 0) {
            return AddressClass.DENIED; // Teredo 2001::/32
        }
        if ((b0 & 0xfe) == 0xfc) {
            return AddressClass.PRIVATE; // fc00::/7 唯一本地
        }
        return AddressClass.PUBLIC;
    }

    private static AddressClass classifyV4(byte[] b, int offset) {
        int a0 = b[offset] & 0xff;
        int a1 = b[offset + 1] & 0xff;
        if (a0 == 0) {
            return AddressClass.DENIED;
        }
        if (a0 == 127) {
            return AddressClass.LOOPBACK;
        }
        if (a0 == 10 || (a0 == 172 && (a1 & 0xf0) == 16) || (a0 == 192 && a1 == 168)) {
            return AddressClass.PRIVATE;
        }
        if (a0 == 169 && a1 == 254) {
            return AddressClass.DENIED;
        }
        if (a0 == 100 && (a1 & 0xc0) == 64) {
            return AddressClass.DENIED; // 100.64.0.0/10 运营商级 NAT, 含阿里云元数据 100.100.100.200
        }
        if (a0 == 192 && a1 == 0 && (b[offset + 2] & 0xff) == 0) {
            return AddressClass.DENIED; // 192.0.0.0/24 协议保留
        }
        if (a0 >= 224) {
            return AddressClass.DENIED; // 组播与保留(含 255.255.255.255)
        }
        return AddressClass.PUBLIC;
    }
}
