package com.uten.imp.security;

import com.uten.imp.config.props.DeploymentProperties;
import jakarta.annotation.PostConstruct;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.core.env.Environment;
import org.springframework.core.env.Profiles;
import org.springframework.stereotype.Component;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * Fail-closed source-network policy for the on-premises API.
 *
 * <p>prod profile (security-17, ADR-110): application-prod.yml 不给默认网段, 部署环境
 * 必须显式配置 {@code UTEN_LOCAL_ALLOWED_CIDRS} (部署脚本 phase3 已生成该项), 未配置即启动失败;
 * 配置里含整段 RFC1918 私网 (/8、/12、/16) 或更宽的网段时启动告警, 提示收窄到公司实际网段。</p>
 */
@Slf4j
@Component
public class LocalNetworkAccessPolicy {

    private static final List<String> WHOLE_PRIVATE_BLOCKS = List.of(
            "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16");

    private final DeploymentProperties deployment;
    private final Environment environment;
    private volatile List<CidrBlock> allowedCidrs;

    @Autowired
    public LocalNetworkAccessPolicy(DeploymentProperties deployment, Environment environment) {
        this.deployment = deployment;
        this.environment = environment;
    }

    public LocalNetworkAccessPolicy(DeploymentProperties deployment) {
        this(deployment, null);
    }

    @PostConstruct
    void validateConfiguration() {
        if (isLocalSite()) {
            allowedCidrs = parseCidrs(deployment.getLocalAllowedCidrs());
            if (environment != null && environment.acceptsProfiles(Profiles.of("prod"))) {
                warnWhenBroad(allowedCidrs);
            }
        }
    }

    /** 覆盖整段私网或更宽的规则只告警不拒绝: 已有部署不因此起不来, 但运维每次启动都会看到。 */
    private static void warnWhenBroad(List<CidrBlock> rules) {
        List<CidrBlock> whole = WHOLE_PRIVATE_BLOCKS.stream().map(CidrBlock::parse).toList();
        for (CidrBlock rule : rules) {
            boolean coversWholeBlock = whole.stream().anyMatch(block ->
                    rule.network().length == block.network().length
                            && rule.prefixBits() <= block.prefixBits()
                            && rule.contains(block.firstAddress()));
            if (coversWholeBlock) {
                log.warn("本地来源网段 uten.deployment.local-allowed-cidrs 含整段私网 {}/{}，"
                                + "生产环境应收窄到公司实际网段 (安全策略 §3.6)",
                        CidrBlock.format(rule.network()), rule.prefixBits());
            }
        }
    }

    public boolean isAllowed(String remoteAddress) {
        if (!isLocalSite()) {
            return true;
        }
        InetAddress address = parseLiteralAddress(remoteAddress);
        if (address == null) {
            return false;
        }
        List<CidrBlock> rules = allowedCidrs;
        if (rules == null) {
            rules = parseCidrs(deployment.getLocalAllowedCidrs());
            allowedCidrs = rules;
        }
        return rules.stream().anyMatch(rule -> rule.contains(address));
    }

    private boolean isLocalSite() {
        return "local".equalsIgnoreCase(deployment.getSite());
    }

    private static List<CidrBlock> parseCidrs(String configured) {
        if (configured == null || configured.isBlank()) {
            throw new IllegalStateException(
                    "uten.deployment.local-allowed-cidrs must not be empty on the local site");
        }
        List<CidrBlock> result = new ArrayList<>();
        for (String entry : configured.split(",", -1)) {
            String cidr = entry.trim();
            if (cidr.isEmpty() || !cidr.equals(entry)) {
                throw new IllegalStateException(
                        "uten.deployment.local-allowed-cidrs must contain canonical CIDRs without whitespace");
            }
            result.add(CidrBlock.parse(cidr));
        }
        if (result.isEmpty()) {
            throw new IllegalStateException(
                    "uten.deployment.local-allowed-cidrs must contain at least one CIDR");
        }
        return List.copyOf(result);
    }

    /**
     * Parses only numeric literals. Never perform DNS resolution using a value derived
     * from a socket or a proxy header.
     */
    private static InetAddress parseLiteralAddress(String value) {
        if (value == null || value.isBlank()) {
            return null;
        }
        if (!value.contains(":")) {
            String[] octets = value.split("\\.", -1);
            if (octets.length != 4) {
                return null;
            }
            byte[] bytes = new byte[4];
            for (int index = 0; index < octets.length; index++) {
                if (!octets[index].matches("[0-9]{1,3}")) {
                    return null;
                }
                if (octets[index].length() > 1 && octets[index].startsWith("0")) {
                    return null;
                }
                int octet = Integer.parseInt(octets[index]);
                if (octet > 255) {
                    return null;
                }
                bytes[index] = (byte) octet;
            }
            try {
                return InetAddress.getByAddress(bytes);
            } catch (UnknownHostException impossible) {
                return null;
            }
        }
        if (!value.matches("[0-9A-Fa-f:.]+")) {
            return null;
        }
        try {
            return InetAddress.getByName(value);
        } catch (UnknownHostException ex) {
            return null;
        }
    }

    private record CidrBlock(byte[] network, int prefixBits) {

        private static CidrBlock parse(String value) {
            int slash = value.indexOf('/');
            if (slash <= 0 || slash == value.length() - 1
                    || slash != value.lastIndexOf('/')) {
                throw invalid(value, null);
            }
            InetAddress address = parseLiteralAddress(value.substring(0, slash));
            if (address == null) {
                throw invalid(value, null);
            }
            String prefixText = value.substring(slash + 1);
            if (!prefixText.matches("0|[1-9][0-9]*")) {
                throw invalid(value, null);
            }
            int prefix;
            try {
                prefix = Integer.parseInt(prefixText);
            } catch (NumberFormatException ex) {
                throw invalid(value, ex);
            }
            int maximum = address.getAddress().length * Byte.SIZE;
            if (prefix < 0 || prefix > maximum) {
                throw invalid(value, null);
            }
            byte[] original = address.getAddress().clone();
            byte[] network = original.clone();
            maskHostBits(network, prefix);
            if (!Arrays.equals(original, network)) {
                throw invalid(value, null);
            }
            return new CidrBlock(network, prefix);
        }

        private InetAddress firstAddress() {
            try {
                return InetAddress.getByAddress(network);
            } catch (UnknownHostException impossible) {
                throw new IllegalStateException(impossible);
            }
        }

        private static String format(byte[] address) {
            try {
                return InetAddress.getByAddress(address).getHostAddress();
            } catch (UnknownHostException impossible) {
                return "?";
            }
        }

        private boolean contains(InetAddress candidate) {
            byte[] address = candidate.getAddress().clone();
            if (address.length != network.length) {
                return false;
            }
            maskHostBits(address, prefixBits);
            return Arrays.equals(network, address);
        }

        private static void maskHostBits(byte[] address, int prefix) {
            int fullBytes = prefix / Byte.SIZE;
            int remainingBits = prefix % Byte.SIZE;
            if (remainingBits != 0 && fullBytes < address.length) {
                int mask = 0xff << (Byte.SIZE - remainingBits);
                address[fullBytes] = (byte) (address[fullBytes] & mask);
                fullBytes++;
            }
            java.util.Arrays.fill(address, fullBytes, address.length, (byte) 0);
        }

        private static IllegalStateException invalid(String value, Exception cause) {
            String message = "Invalid CIDR in uten.deployment.local-allowed-cidrs: " + value;
            return cause == null
                    ? new IllegalStateException(message)
                    : new IllegalStateException(message, cause);
        }
    }
}
