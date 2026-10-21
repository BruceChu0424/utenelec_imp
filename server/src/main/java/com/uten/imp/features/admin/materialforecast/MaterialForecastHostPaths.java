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
    private MaterialForecastDevelopmentPayload developmentPayload;
    private volatile Path preparedDevelopmentPayload;
    @org.springframework.beans.factory.annotation.Autowired(required=false)
    void setDevelopmentPayload(MaterialForecastDevelopmentPayload developmentPayload) {
        this.developmentPayload=developmentPayload;
    }
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
        Path prepared=preparedDevelopmentPayload;
        return prepared!=null?prepared:packagedPayload(applicationHome());
    }
    Path payloadDirectory(java.util.function.BooleanSupplier abort) {
        if(nonblank(properties.getPayloadDirectory()))return absolute(properties.getPayloadDirectory());
        Path home=applicationHome();
        if(developmentPayload!=null) {
            Path development=developmentPayload.resolve(home,abort);
            if(development!=null){preparedDevelopmentPayload=development;return development;}
        }
        return packagedPayload(home);
    }
    private static Path applicationHome(){return new ApplicationHome(MaterialForecastHostPaths.class).getDir().toPath().toAbsolutePath().normalize();}
    void cancelDevelopmentPreparation(){if(developmentPayload!=null)developmentPayload.cancel();}
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
    static boolean containsManagedInterpreter(Path cache,Path interpreter)throws IOException {
        Path parent=interpreter.getParent();
        if(parent==null)return false;
        rejectLinks(interpreter);
        Path realParent=parent.toRealPath();
        // A receipt must name an actual directory, not a junction/link into the
        // cache. Windows packaged hosts can expose two unlinked names for that
        // same directory; toRealPath alone does not unify those OS aliases.
        if(!realParent.equals(parent))return false;
        if(realParent.startsWith(cache))return true;
        if(!windows())return false;
        for(Path ancestor=realParent;ancestor!=null;ancestor=ancestor.getParent()) {
            if(Files.isSameFile(cache,ancestor))return true;
        }
        return false;
    }
    static Path absolute(String value) {
        Path path=Path.of(value).normalize();
        if(!path.isAbsolute())throw new IllegalStateException("Market bootstrap path must be absolute");
        return path;
    }
    static boolean windows(){return System.getProperty("os.name","").toLowerCase(Locale.ROOT).contains("windows");}
    private static boolean nonblank(String value){return value!=null&&!value.isBlank();}
}
