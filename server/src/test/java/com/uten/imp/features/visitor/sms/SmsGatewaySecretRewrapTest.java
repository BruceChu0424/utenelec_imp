package com.uten.imp.features.visitor.sms;

import java.util.Optional;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.transaction.PlatformTransactionManager;
import static com.uten.imp.features.visitor.sms.SmsRuntimeTestSupport.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SmsGatewaySecretRewrapTest {
    @Test void oldKeyVersionRewrapsBothColumnsAndAdvancesRevisionWithoutChangingPolicy() {
        var old=row(cipher("1"),4,"ALIYUN");var current=cipher("2");var store=mock(SmsGatewaySettingsStore.class);
        when(store.lockCurrent()).thenReturn(Optional.of(old));when(store.save(any(),eq(4L),eq(true))).thenReturn(true);
        assertThat(new SmsGatewaySecretRewrap(store,current,mock(PlatformTransactionManager.class)).rewrap()).isEqualTo(1);
        var saved=ArgumentCaptor.forClass(SmsGatewaySettingsStore.Row.class);verify(store).save(saved.capture(),eq(4L),eq(true));
        assertThat(saved.getValue().version()).isEqualTo(5);assertThat(saved.getValue().accessKeyIdCipher()).startsWith("g2:");
        assertThat(current.decrypt(saved.getValue().accessKeyIdCipher(),SmsGatewaySettingsStore.idAad())).isEqualTo(ID);
        assertThat(current.decrypt(saved.getValue().accessKeySecretCipher(),SmsGatewaySettingsStore.secretAad())).isEqualTo(SECRET);
        assertThat(saved.getValue().provider()).isEqualTo(old.provider());
    }
    @Test void mismatchedCipherContextRetainsExistingBytesAndNeverWritesABrokenPair() {
        var current=cipher("2");var source=row(cipher("1"),4,"ALIYUN");
        var invalid=new SmsGatewaySettingsStore.Row(4,source.mode(),source.provider(),source.endpoint(),source.signName(),source.templateCode(),
                source.accessKeySecretCipher(),source.accessKeyIdCipher(),source.accessKeyIdHint(),source.updatedAt(),source.updatedBy());
        var store=mock(SmsGatewaySettingsStore.class);when(store.lockCurrent()).thenReturn(Optional.of(invalid));
        assertThat(new SmsGatewaySecretRewrap(store,current,mock(PlatformTransactionManager.class)).rewrap()).isZero();
        verify(store,never()).save(any(),anyLong(),anyBoolean());
    }
}
