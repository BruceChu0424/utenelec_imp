package com.uten.imp.features.admin.materialforecast;

import com.uten.imp.config.props.DeploymentProperties;
import com.uten.imp.application.port.MaterialForecastRuntimePort;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;
import java.nio.file.Path;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class MaterialForecastRuntimeAccessTest {
    @Test void cloudProfileWithoutASupervisorStillProvidesASafeNeutralReadPort() {
        var policy=mock(MaterialForecastPolicyService.class);var desired=MaterialForecastPolicyService.policy(true,15,1200,30);when(policy.current()).thenReturn(desired);
        var paths=mock(MaterialForecastHostPaths.class);when(paths.stateDirectory()).thenReturn(Path.of("snapshot-fixture").toAbsolutePath());
        @SuppressWarnings("unchecked") ObjectProvider<MaterialForecastSupervisor> owner=mock(ObjectProvider.class);
        var deployment=new DeploymentProperties();deployment.setSite("cloud");
        var port=new MaterialForecastRuntimeAccess(policy,paths,owner,deployment);
        assertThat(port.configuration()).isEqualTo(desired);assertThat(port.runtime().state()).isEqualTo("NOT_LOCAL");assertThat(port.runtime().configurationApplied()).isFalse();
        assertThat(port.acknowledges(java.time.Instant.now(),desired.revision(),java.util.UUID.randomUUID().toString())).isFalse();
    }
    @Test void statusReadsNeverStartACollectorAndUseTheSameDesiredPolicyObject() {
        var policy=mock(MaterialForecastPolicyService.class);var desired=MaterialForecastPolicyService.policy(false,15,1200,30);
        var supervisor=mock(MaterialForecastSupervisor.class);
        when(supervisor.state(desired)).thenReturn(new MaterialForecastRuntimePort.State("DISABLED",false,false,desired.revision(),desired.revision(),true,null,null,null,null));
        @SuppressWarnings("unchecked") ObjectProvider<MaterialForecastSupervisor> owner=mock(ObjectProvider.class);when(owner.getIfAvailable()).thenReturn(supervisor);
        var port=new MaterialForecastRuntimeAccess(policy,mock(MaterialForecastHostPaths.class),owner,new DeploymentProperties());
        assertThat(port.runtime(desired).configurationApplied()).isTrue();verify(supervisor,never()).start();verifyNoInteractions(policy);
    }
}
