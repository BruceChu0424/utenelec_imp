package com.uten.imp.features.admin.materialforecast;

import com.uten.imp.config.props.MaterialForecastProperties;
import com.uten.imp.config.props.StorageProperties;
import lombok.RequiredArgsConstructor;
import org.springframework.boot.system.ApplicationHome;
import org.springframework.stereotype.Component;
import java.io.IOException;
import java.nio.file.*;
import java.util.Locale;

/** Host bootstrap only. Portable policy never carries paths, commands or an interpreter choice. */
@Component
@RequiredArgsConstructor
public class MaterialForecastHostPaths {
    private final StorageProperties storage;
    private final MaterialForecastProperties properties;
    public Path stateDirectory() {
        String override=properties.getSnapshotDirectory();
        if(override!=null&&!override.isBlank())return absolute(override);
        String root=switch(storage.getProvider()) {
            case "internal" -> storage.getInternal().getRoot();
            case "local" -> storage.getLocalDir();
            default -> throw new IllegalStateException("Durable market storage unavailable");
        };
        if(root==null||root.isBlank())throw new IllegalStateException("Durable market storage unavailable");
        Path state=Path.of(root).toAbsolutePath().normalize().resolve("material-forecast");
        if(state.toString().replace('\\','/').startsWith("/opt/uten-imp/"))throw new IllegalStateException("Immutable release storage forbidden");
        return state;
    }
    public Path cacheDirectory() {
        if(nonblank(properties.getCacheDirectory()))return absolute(properties.getCacheDirectory());
        if(windows()) {
            String root=System.getenv("LOCALAPPDATA");
            Path local=nonblank(root)?Path.of(root):Path.of(System.getProperty("user.home"),"AppData","Local");
            return local.resolve("UtenIMP/cache/material-forecast").toAbsolutePath().normalize();
        }
        String xdg=System.getenv("XDG_CACHE_HOME");
        return nonblank(xdg)?absolute(xdg).resolve("uten-imp/material-forecast"):Path.of("/var/cache/uten-imp/material-forecast");
    }
    public Path payloadDirectory() {
        if(nonblank(properties.getPayloadDirectory()))return absolute(properties.getPayloadDirectory());
        return packagedPayload(new ApplicationHome(MaterialForecastHostPaths.class).getDir().toPath().toAbsolutePath().normalize());
    }
    static Path packagedPayload(Path applicationHome) {
        if(applicationHome.getFileName()!=null&&applicationHome.getFileName().toString().equals("server")) {
            return applicationHome.resolve("material_forecast");
        }
        return applicationHome.resolve("server/material_forecast");
    }
    public void ensureState()throws IOException {ensureSafeDirectory(stateDirectory());}
    static void ensureSafeDirectory(Path path)throws IOException {
        rejectLinks(path);
        Files.createDirectories(path);
        rejectLinks(path);
        if(!path.toRealPath().equals(path))throw new IOException("Unsafe market directory");
    }
    static void rejectLinks(Path path)throws IOException {
        Path current=path;
        while(current!=null) {
            if(Files.isSymbolicLink(current))throw new IOException("Linked market directory forbidden");
            current=current.getParent();
        }
    }
    static Path absolute(String value) {
        Path path=Path.of(value).normalize();
        if(!path.isAbsolute())throw new IllegalStateException("Market bootstrap path must be absolute");
        return path;
    }
    static boolean windows(){return System.getProperty("os.name","").toLowerCase(Locale.ROOT).contains("windows");}
    private static boolean nonblank(String value){return value!=null&&!value.isBlank();}
}
