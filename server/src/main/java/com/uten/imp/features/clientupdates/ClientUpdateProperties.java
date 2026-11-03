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
    /** Public trust material only. Private signing keys never belong on the publication server. */
    private String windowsPublisherSha256 = "";
    private String windowsSignatureVerifier = "/usr/bin/osslsigncode";
    private String windowsSignatureCaFile = "";
    private String windowsSignatureTsaCaFile = "";
    private String windowsSignatureCrlFile = "";
    private String windowsSignatureTsaCrlFile = "";
}
