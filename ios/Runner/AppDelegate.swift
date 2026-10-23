import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var clientUpdateChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "com.uten.imp/client_update",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
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
        "platform": "ios",
        "architecture": architecture,
        "currentVersion": version,
        "currentBuild": build,
        "stagingDirectory": staging.path,
        "supportsInPlaceUpdate": false,
        "requiresSystemConfirmation": true,
      ])
    }
    clientUpdateChannel = channel
  }
}
