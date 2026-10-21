package com.uten.imp.features.master.goods.pricing;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Getter
@Setter
@Component
@ConfigurationProperties(prefix="uten.material-forecast")
public class MaterialForecastProperties {
    /** Operator controlled absolute directory. Empty disables the integration. */
    private String snapshotDirectory="";
    private int maxDataAgeDays=3;
}
