package com.uten.imp.features.visitor.sms;

import java.util.Optional;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;
import org.springframework.mock.env.MockEnvironment;
import static com.uten.imp.features.visitor.sms.SmsRuntimeTestSupport.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

class DynamicSmsGatewayTest {
    @Test void committedRevisionBuildsANewSenderWithoutChangingAnAlreadyPreparedIssuance() {
        var cipher=cipher("1");var store=mock(SmsGatewaySettingsStore.class);var factory=mock(SmsGatewayFactory.class);
        var current=new AtomicReference<>(row(cipher,1,"ALIYUN"));
        when(store.current()).thenAnswer(call->Optional.of(current.get()));
        var runtime=new SmsGatewayRuntime(store,environment(),cipher,new MockEnvironment());
        SmsGateway first=mock(SmsGateway.class),second=mock(SmsGateway.class);
        when(first.sendCode(any(),any())).thenReturn(SmsSendResult.UNCERTAIN);
        when(second.sendCode(any(),any())).thenReturn(SmsSendResult.REJECTED);
        when(factory.create(any())).thenReturn(first,second);
        var router=new DynamicSmsGateway(runtime,factory);
        var prepared=router.prepare();router.prepare();
        verify(factory,times(1)).create(any());
        current.set(row(cipher,2,"DISABLED"));
        assertThat(router.prepare().sendCode("13800138000","123456")).isEqualTo(SmsSendResult.REJECTED);
        assertThat(prepared.sendCode("13800138000","123456")).isEqualTo(SmsSendResult.UNCERTAIN);
        verify(first,times(1)).sendCode(any(),any());verify(second,times(1)).sendCode(any(),any());
        assertThat(prepared.developmentCodeAllowed()).isFalse();
    }
    @Test void inFlightNetworkCallCompletesOnOldClientAndNeverGetsReplayedAfterSave() throws Exception {
        var cipher=cipher("1");var store=mock(SmsGatewaySettingsStore.class);var factory=mock(SmsGatewayFactory.class);
        var current=new AtomicReference<>(row(cipher,1,"ALIYUN"));
        when(store.current()).thenAnswer(call->Optional.of(current.get()));
        CountDownLatch entered=new CountDownLatch(1),release=new CountDownLatch(1);
        SmsGateway old=mock(SmsGateway.class),next=mock(SmsGateway.class);
        when(old.sendCode(any(),any())).thenAnswer(call->{entered.countDown();assertThat(release.await(5,TimeUnit.SECONDS)).isTrue();return SmsSendResult.UNCERTAIN;});
        when(next.sendCode(any(),any())).thenReturn(SmsSendResult.ACCEPTED);
        when(factory.create(any())).thenReturn(old,next);
        var router=new DynamicSmsGateway(new SmsGatewayRuntime(store,environment(),cipher,new MockEnvironment()),factory);
        try(var executor=Executors.newVirtualThreadPerTaskExecutor()) {
            var inFlight=executor.submit(()->router.prepare().sendCode("13800138000","123456"));
            assertThat(entered.await(5,TimeUnit.SECONDS)).isTrue();
            current.set(row(cipher,2,"ALIYUN"));
            assertThat(router.prepare().sendCode("13800138000","654321")).isEqualTo(SmsSendResult.ACCEPTED);
            release.countDown();assertThat(inFlight.get(5,TimeUnit.SECONDS)).isEqualTo(SmsSendResult.UNCERTAIN);
        } finally { release.countDown(); }
        verify(old,times(1)).sendCode(any(),any());verify(next,times(1)).sendCode(any(),any());
    }
}
