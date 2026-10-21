package com.uten.imp.config.props;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Getter
@Setter
@Component
@ConfigurationProperties(prefix="uten.material-forecast")
public class MaterialForecastProperties {
    /** Optional host bootstrap override; empty derives state from durable attachment storage. */
    private String snapshotDirectory="";
    private int maxDataAgeDays=3;
    private boolean manageRuntime=true;
    private String payloadDirectory="";
    private String cacheDirectory="";
    private String basePythonExecutable="";
}
