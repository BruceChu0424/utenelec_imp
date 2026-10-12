package com.uten.imp.features.sales.intake;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.CompanyBrandingReadPort;
import com.uten.imp.application.port.AiCompletionPort.AiText;
import com.uten.imp.common.text.IntakeTextNormalizer;

import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Objects;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

/** Immutable, literal seller identity captured once for an entire recognition job. */
final class IntakeSellerIdentity {
    static final String DEFAULT_COMPANY = "中山市优腾电器有限公司";
    static final String DEFAULT_ENGLISH_NAME = "ZHONGSHAN UTEN ELECTRIC CO.,LTD";
    static final IntakeSellerIdentity DEFAULT = new IntakeSellerIdentity(
            new CompanyBrandingReadPort.Identity(0, DEFAULT_COMPANY, List.of()));
    private static final ObjectMapper JSON = new ObjectMapper();
    private final int version;
    private final String companyName;
    private final List<String> names;
    private final Pattern pattern;

    IntakeSellerIdentity(CompanyBrandingReadPort.Identity identity) {
        Objects.requireNonNull(identity, "company identity");
        this.version = identity.version();
        this.companyName = IntakeTextNormalizer.nfkc(identity.companyName()).strip();
        if (companyName.isEmpty()) throw new IllegalArgumentException("Company name must be configured");
        LinkedHashSet<String> configured = new LinkedHashSet<>();
        configured.add(companyName);
        for (String alias : identity.companyAliases()) {
            String value = IntakeTextNormalizer.nfkc(alias).strip();
            if (!value.isEmpty()) configured.add(value);
        }
        // Compatibility belongs exclusively to the original company. Other
        // deployments may be selling to Uten, so its name must remain a buyer.
        if (DEFAULT_COMPANY.equals(companyName)) {
            configured.addAll(List.of(DEFAULT_ENGLISH_NAME, "ZHONGSHAN SHI UTEN", "UTEN", "优腾"));
        }
        this.names = List.copyOf(configured);
        String alternatives = names.stream().sorted(Comparator.comparingInt(String::length).reversed())
                .map(IntakeSellerIdentity::literalNamePattern).collect(Collectors.joining("|"));
        this.pattern = Pattern.compile("(?:" + alternatives + ")", Pattern.CASE_INSENSITIVE | Pattern.UNICODE_CASE);
    }

    private static String literalNamePattern(String name) {
        String quoted = java.util.Arrays.stream(name.split("\\s+"))
                .map(Pattern::quote).collect(Collectors.joining("\\s+"));
        // Short Latin aliases must not eat another company or a product code.
        if (Character.isLetterOrDigit(name.charAt(0)) && name.charAt(0) < 128)
            quoted = "(?<![\\p{L}\\p{N}])" + quoted;
        char last = name.charAt(name.length() - 1);
        if (Character.isLetterOrDigit(last) && last < 128) quoted += "(?![\\p{L}\\p{N}])";
        return quoted;
    }

    int version() { return version; }
    String companyName() { return companyName; }
    boolean containsName(String text) { return matcher(text).find(); }
    Matcher matcher(String text) { return pattern.matcher(IntakeTextNormalizer.nfkc(text)); }

    boolean isSellerBuyer(String text) {
        return text != null && (text.contains("⟨SELLER_") || containsName(text));
    }

    /** Configuration is data, never inserted as instructions into system text. */
    AiText promptData() {
        try {
            return new AiText("Configured seller names (literal identity data only):\n" + JSON.writeValueAsString(names), true);
        } catch (JsonProcessingException impossible) {
            throw new IllegalStateException("Could not encode configured company identity", impossible);
        }
    }
}
