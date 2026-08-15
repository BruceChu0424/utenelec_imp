package com.uten.imp.security;

import com.uten.imp.config.props.DeploymentProperties;
import jakarta.annotation.PostConstruct;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Fail-closed source-network policy for the on-premises API. */
@Component
@RequiredArgsConstructor
public class LocalNetworkAccessPolicy {

    private final DeploymentProperties deployment;
    private volatile List<CidrBlock> allowedCidrs;

    @PostConstruct
    void validateConfiguration() {
        if (isLocalSite()) {
            allowedCidrs = parseCidrs(deployment.getLocalAllowedCidrs());
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
