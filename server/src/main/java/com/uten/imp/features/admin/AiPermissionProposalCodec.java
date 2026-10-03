package com.uten.imp.features.admin;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.CryptoProperties;
import com.uten.imp.config.props.JwtProperties;
import org.springframework.stereotype.Component;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.Base64;
import java.util.UUID;

/** Stateless, short-lived confirmation intent. Domain separation prevents credential-token reuse. */
@Component
public class AiPermissionProposalCodec {
    private final ObjectMapper json;
    private final byte[] signingKey;
    private final String purpose;

    public AiPermissionProposalCodec(ObjectMapper json, CryptoProperties crypto, JwtProperties jwt) {
        this.json = json;
        String key = crypto.getHmacKey();
        byte[] configured = key == null ? null : key.getBytes(StandardCharsets.UTF_8);
        signingKey = configured == null || configured.length < 32 ? null : configured;
        purpose = "uten|ai-chat-single-permission-grant|v1|" + jwt.getIssuer() + "|";
    }

    public boolean available() { return signingKey != null; }

    public record Proposal(UUID actorId, long actorAuthVersion, long authorizationEpoch,
            UUID targetId, long targetAuthVersion, UUID permissionId, String permissionCode,
            long issuedAt, long expiresAt) {}

    public String encode(Proposal proposal) {
        if (!available()) throw new ApiException(ErrorCode.BUSINESS, "授权确认签名未配置，请联系管理员");
        try {
            String payload = Base64.getUrlEncoder().withoutPadding().encodeToString(json.writeValueAsBytes(proposal));
            return payload + "." + Base64.getUrlEncoder().withoutPadding().encodeToString(sign(payload));
        } catch (Exception e) {
            throw new ApiException(ErrorCode.BUSINESS, "无法准备授权确认，请稍后重试");
        }
    }

    public Proposal decode(String token) {
        try {
            if (!available() || token == null || token.length() > 4096) throw new IllegalArgumentException();
            String[] parts = token.split("\\.", -1);
            if (parts.length != 2 || !MessageDigest.isEqual(sign(parts[0]), Base64.getUrlDecoder().decode(parts[1]))) {
                throw new IllegalArgumentException();
            }
            Proposal proposal = json.readValue(Base64.getUrlDecoder().decode(parts[0]), Proposal.class);
            long now = Instant.now().getEpochSecond();
            if (proposal.actorId() == null || proposal.targetId() == null || proposal.permissionId() == null
                    || proposal.permissionCode() == null || proposal.issuedAt() > now
                    || proposal.expiresAt() <= now || proposal.expiresAt() - proposal.issuedAt() > 600) {
                throw new IllegalArgumentException();
            }
            return proposal;
        } catch (Exception e) {
            throw new ApiException(ErrorCode.CONFLICT, "授权确认已过期或无效，请重新发起授权请求");
        }
    }

    private byte[] sign(String payload) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(signingKey, "HmacSHA256"));
        return mac.doFinal((purpose + payload).getBytes(StandardCharsets.UTF_8));
    }
}
