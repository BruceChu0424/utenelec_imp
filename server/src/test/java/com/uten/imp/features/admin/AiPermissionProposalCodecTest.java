package com.uten.imp.features.admin;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.config.props.CryptoProperties;
import com.uten.imp.config.props.JwtProperties;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class AiPermissionProposalCodecTest {
    private AiPermissionProposalCodec codec(String issuer) {
        var crypto = new CryptoProperties();
        crypto.setHmacKey("test-only-proposal-signing-key-not-for-production-123");
        var jwt = new JwtProperties();
        jwt.setIssuer(issuer);
        return new AiPermissionProposalCodec(new ObjectMapper(), crypto, jwt);
    }
    private AiPermissionProposalCodec.Proposal proposal(long expires) {
        return new AiPermissionProposalCodec.Proposal(UUID.randomUUID(), 7, 13,
                UUID.randomUUID(), 8, UUID.randomUUID(), "goods:view", Instant.now().getEpochSecond(), expires);
    }
    @Test void signedIntentRoundTripsWithoutTrustingClientFields() {
        var codec = codec("local");
        var expected = proposal(Instant.now().plusSeconds(600).getEpochSecond());
        assertThat(codec.decode(codec.encode(expected))).isEqualTo(expected);
    }
    @Test void tamperedPayloadAndWrongEnvironmentAreRejected() {
        var local = codec("local");
        String token = local.encode(proposal(Instant.now().plusSeconds(600).getEpochSecond()));
        assertThatThrownBy(() -> local.decode("A" + token.substring(1))).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> codec("different-environment").decode(token)).isInstanceOf(ApiException.class);
    }
    @Test void expiredAndOverlongLifetimesAreRejected() {
        var codec = codec("local");
        String expired = codec.encode(proposal(Instant.now().minusSeconds(1).getEpochSecond()));
        String overlong = codec.encode(proposal(Instant.now().plusSeconds(900).getEpochSecond()));
        assertThatThrownBy(() -> codec.decode(expired)).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> codec.decode(overlong)).isInstanceOf(ApiException.class);
    }
}
