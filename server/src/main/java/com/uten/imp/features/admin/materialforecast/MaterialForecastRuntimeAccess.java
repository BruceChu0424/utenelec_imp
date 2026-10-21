package com.uten.imp.features.admin.materialforecast;

import com.uten.imp.application.port.MaterialForecastRuntimePort;
import com.uten.imp.config.props.DeploymentProperties;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Component;
import java.nio.file.Path;
import java.time.Instant;

/** Always present, including cloud; only the local-profile supervisor may own a process. */
@Component
public class MaterialForecastRuntimeAccess implements MaterialForecastRuntimePort {
    private final MaterialForecastPolicyService policy;
    private final MaterialForecastHostPaths paths;
    private final ObjectProvider<MaterialForecastSupervisor> supervisor;
    private final DeploymentProperties deployment;
    public MaterialForecastRuntimeAccess(MaterialForecastPolicyService policy,MaterialForecastHostPaths paths,
            ObjectProvider<MaterialForecastSupervisor> supervisor,DeploymentProperties deployment){this.policy=policy;this.paths=paths;this.supervisor=supervisor;this.deployment=deployment;}
    @Override public Policy configuration(){return policy.current();}
    @Override public Path snapshotDirectory(){return paths.stateDirectory();}
    @Override public State runtime() {
        return runtime(configuration());
    }
    @Override public State runtime(Policy desired) {
        var owner=supervisor.getIfAvailable();
        if(owner==null||!"local".equalsIgnoreCase(deployment.getSite())) {
            return new State("NOT_LOCAL",false,false,desired.revision(),null,false,null,null,null,null);
        }
        return owner.state(desired);
    }
    @Override public boolean acknowledges(Instant generated,String revision,String runId) {
        var owner=supervisor.getIfAvailable();
        return owner!=null&&owner.acknowledges(generated,revision,runId,configuration());
    }
    @Override public Instant confirmationExpiresAt(Policy desired) {
        var owner=supervisor.getIfAvailable();
        return owner==null?null:owner.confirmationExpiresAt(desired);
    }
}
