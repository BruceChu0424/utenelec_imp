import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var clientUpdateChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let channel = FlutterMethodChannel(
      name: "com.uten.imp/client_update",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "getInstallContext" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let info = Bundle.main.infoDictionary ?? [:]
      let version = info["CFBundleShortVersionString"] as? String ?? ""
      let build = Int(info["CFBundleVersion"] as? String ?? "") ?? 0
      let staging = FileManager.default.temporaryDirectory.appendingPathComponent("client-updates", isDirectory: true)
      try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
      #if arch(arm64)
      let architecture = "arm64"
      #elseif arch(x86_64)
      let architecture = "x64"
      #else
      let architecture = "universal"
      #endif
      result([
        "platform": "macos",
        "architecture": architecture,
        "currentVersion": version,
        "currentBuild": build,
        "stagingDirectory": staging.path,
        "supportsInPlaceUpdate": false,
        "requiresSystemConfirmation": true,
      ])
    }
    clientUpdateChannel = channel

    super.awakeFromNib()
  }
}
