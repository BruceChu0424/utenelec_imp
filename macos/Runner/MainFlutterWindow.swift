import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var clientUpdateChannel: FlutterMethodChannel?
  private var desktopWindowChannel: FlutterMethodChannel?
  private enum DesktopMode: String { case login, main }
  private var requestedMode = DesktopMode.login
  private var appliedMode: DesktopMode?
  private var mainFrame: NSRect?
  private var mainCollectionBehavior: NSWindow.CollectionBehavior = []
  private var restoreMainFullScreen = false
  private var fullScreenTransition = false
  private var exitingFullScreenForLogin = false
  private var leftMouseDown: NSEvent?
  private var windowObservers: [NSObjectProtocol] = []

  // Borderless windows otherwise cannot receive keyboard focus on macOS.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func awakeFromNib() {
    mainCollectionBehavior = collectionBehavior.union(.fullScreenPrimary)
    title = "UTEN"
    // Configure the login frame before creating/showing the Flutter surface.
    // Authentication changes only this window's presentation, not its engine.
    applyMode(.login)
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

    installDesktopWindowChannel(flutterViewController)
    observeFullScreenTransitions()

    super.awakeFromNib()
  }

  override func sendEvent(_ event: NSEvent) {
    // Method-channel messages arrive after sendEvent has returned; currentEvent
    // alone is not a reliable way to recover the original mouse-down event.
    if event.type == .leftMouseDown { leftMouseDown = event }
    if event.type == .leftMouseUp { leftMouseDown = nil }
    super.sendEvent(event)
  }

  override func performClose(_ sender: Any?) {
    if styleMask.contains(.titled) {
      super.performClose(sender)
    } else if delegate?.windowShouldClose?(self) != false {
      // AppKit's normal performClose requires a native titlebar close button.
      // Honor the delegate while supporting the login button and Command+W.
      close()
    }
  }

  private func installDesktopWindowChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "com.uten.imp/desktop_window",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "WINDOW_UNAVAILABLE", message: "The window is closing.", details: nil))
        return
      }
      switch call.method {
      case "setMode":
        guard let value = call.arguments as? String, let mode = DesktopMode(rawValue: value) else {
          result(FlutterError(code: "INVALID_MODE", message: "Expected login or main.", details: nil))
          return
        }
        self.requestMode(mode)
        result(nil)
      case "beginDrag":
        if self.appliedMode == .login,
           NSEvent.pressedMouseButtons & 1 != 0,
           let event = self.leftMouseDown,
           event.windowNumber == self.windowNumber {
          self.performDrag(with: event)
        }
        result(nil)
      case "minimize":
        self.miniaturize(nil)
        result(nil)
      case "close":
        result(nil)
        // Do not tear down Flutter/the channel while it is handling this call.
        DispatchQueue.main.async { [weak self] in self?.performClose(nil) }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    desktopWindowChannel = channel
  }

  private func requestMode(_ mode: DesktopMode) {
    requestedMode = mode
    if mode == appliedMode && !exitingFullScreenForLogin { return }
    if mode == .login && appliedMode == .main {
      if styleMask.contains(.fullScreen) || fullScreenTransition {
        restoreMainFullScreen = true
        exitingFullScreenForLogin = true
        if !fullScreenTransition { toggleFullScreen(nil) }
        return
      }
      mainFrame = frame
    }
    if fullScreenTransition { return }
    applyMode(mode)
  }

  private func applyMode(_ mode: DesktopMode) {
    guard appliedMode != mode else { return }
    leftMouseDown = nil
    let visibleFrame = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    contentMinSize = .zero
    contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    if mode == .login {
      // Closable/miniaturizable retain native menu semantics without a titlebar.
      styleMask = [.borderless, .closable, .miniaturizable]
      collectionBehavior = [.fullScreenNone]
      titleVisibility = .hidden
      titlebarAppearsTransparent = true
      isMovableByWindowBackground = false
      hasShadow = true
      let size = NSSize(width: min(460, visibleFrame.width), height: min(720, visibleFrame.height))
      let origin = NSPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2)
      setFrame(NSRect(origin: origin, size: size), display: true)
    } else {
      styleMask = [.titled, .closable, .miniaturizable, .resizable]
      collectionBehavior = mainCollectionBehavior
      titleVisibility = .visible
      titlebarAppearsTransparent = false
      let target: NSRect
      if let rememberedFrame = mainFrame {
        target = constrainToVisibleScreen(rememberedFrame, fallback: visibleFrame)
      } else {
        let requested = frameRect(forContentRect: NSRect(x: 0, y: 0, width: 1280, height: 800))
        let size = NSSize(width: min(requested.width, visibleFrame.width), height: min(requested.height, visibleFrame.height))
        target = NSRect(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2, width: size.width, height: size.height)
      }
      setFrame(target, display: true)
      let availableContent = contentRect(forFrameRect: target).size
      contentMinSize = NSSize(width: min(960, availableContent.width), height: min(640, availableContent.height))
    }
    appliedMode = mode
    if isVisible && NSApp.isActive { makeKey() }
    if mode == .main && restoreMainFullScreen {
      restoreMainFullScreen = false
      DispatchQueue.main.async { [weak self] in
        guard let self = self, self.requestedMode == .main,
              self.appliedMode == .main, !self.fullScreenTransition,
              !self.styleMask.contains(.fullScreen) else { return }
        self.toggleFullScreen(nil)
      }
    }
  }

  private func constrainToVisibleScreen(_ remembered: NSRect, fallback: NSRect) -> NSRect {
    // A monitor may have disappeared while the login window was open.
    let matchingScreen = NSScreen.screens.max { first, second in
      let a = first.visibleFrame.intersection(remembered)
      let b = second.visibleFrame.intersection(remembered)
      return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
    }
    let candidate = matchingScreen?.visibleFrame ?? fallback
    let bounds = candidate.intersects(remembered) ? candidate : fallback
    let size = NSSize(width: min(remembered.width, bounds.width), height: min(remembered.height, bounds.height))
    return NSRect(
      x: min(max(remembered.minX, bounds.minX), bounds.maxX - size.width),
      y: min(max(remembered.minY, bounds.minY), bounds.maxY - size.height),
      width: size.width, height: size.height
    )
  }

  private func observeFullScreenTransitions() {
    let center = NotificationCenter.default
    windowObservers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      guard let self = self else { return }
      self.mainFrame = self.frame
      self.fullScreenTransition = true
    })
    windowObservers.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      guard let self = self else { return }
      self.fullScreenTransition = false
      if self.requestedMode == .login { self.requestMode(.login) }
    })
    windowObservers.append(center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      self?.fullScreenTransition = true
    })
    windowObservers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      guard let self = self else { return }
      self.fullScreenTransition = false
      guard self.exitingFullScreenForLogin else { return }
      self.exitingFullScreenForLogin = false
      // Do not save the full-screen frame as the ordinary main-window bounds.
      if self.requestedMode == .login {
        self.applyMode(.login)
      } else {
        // A rapid logout/login can cancel the compact-window transition.
        self.restoreMainFullScreen = false
        self.toggleFullScreen(nil)
      }
    })
  }

  deinit {
    for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    desktopWindowChannel?.setMethodCallHandler(nil)
    clientUpdateChannel?.setMethodCallHandler(nil)
  }
}
