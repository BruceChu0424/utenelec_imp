package com.uten.imp.features.clientupdates;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

/** Client binaries have an independent durable namespace; they are never server release artifacts. */
@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "uten.client-updates")
public class ClientUpdateProperties {
    private String directory = "";
    private long maxPackageBytes = 536870912L;
    private int pollIntervalSeconds = 300;
    private int maxReleases = 200;
    private long minFreeBytes = 1073741824L;
}
