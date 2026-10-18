package com.uten.imp.features.auth;

import org.junit.jupiter.api.Test;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import static org.assertj.core.api.Assertions.assertThat;

class TotpTest {
    private static final String SECRET = Totp.encode("12345678901234567890".getBytes(StandardCharsets.US_ASCII));

    @Test void rfc6238Sha1VectorsIncludingBeyond2038() {
        long[] times = {59L,1111111109L,1111111111L,1234567890L,2000000000L,20000000000L};
        String[] expected = {"94287082","07081804","14050471","89005924","69279037","65353130"};
        for (int i=0;i<times.length;i++) assertThat(Totp.code(SECRET,times[i]/30,8)).isEqualTo(expected[i]);
    }

    @Test void acceptsOnlySixDigitsWithinBoundedWindowAndNeverAnAcceptedStep() {
        Instant now=Instant.ofEpochSecond(1234567890L);
        long step=now.getEpochSecond()/30;
        assertThat(Totp.matchingStep(SECRET,Totp.code(SECRET,step,6),now,null)).isEqualTo(step);
        assertThat(Totp.matchingStep(SECRET,Totp.code(SECRET,step,6),now,step)).isNegative();
        assertThat(Totp.matchingStep(SECRET,Totp.code(SECRET,step-1,6),now,step)).isNegative();
        assertThat(Totp.matchingStep(SECRET,Totp.code(SECRET,step-1,6),now,null)).isEqualTo(step-1);
        assertThat(Totp.matchingStep(SECRET,Totp.code(SECRET,step+1,6),now,null)).isEqualTo(step+1);
        assertThat(Totp.matchingStep(SECRET,Totp.code(SECRET,step+2,6),now,null)).isNegative();
        for(String invalid:new String[]{"", "12345", "１２３４５６", " 123456", "1234567"})
            assertThat(Totp.matchingStep(SECRET,invalid,now,null)).isNegative();
    }

    @Test void provisioningUsesIndependent160BitSecretsAndRedactsDtoText() {
        assertThat(Totp.newSecret()).matches("[A-Z2-7]{32}").isNotEqualTo(Totp.newSecret());
        assertThat(new RemoteMfaService.Enrollment("secret", "uri", Instant.EPOCH).toString()).doesNotContain("secret", "uri");
        assertThat(new RemoteMfaController.Code("123456").toString()).doesNotContain("123456");
    }
}
