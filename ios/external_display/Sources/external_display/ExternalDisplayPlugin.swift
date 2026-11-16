import Flutter
import UIKit

public class ExternalDisplayPlugin: NSObject, FlutterPlugin {
    /// 外接畫面參數通道就緒後的回呼（主畫面等待用）
    public static var connectReturn: (() -> Void)?
    /// 主畫面外接螢幕狀態事件 sink（true = 已連接，false = 已拔除）
    public static var mainViewEvents: FlutterEventSink?
    /// 外接畫面接收參數的事件 sink
    public static var externalViewEvents: FlutterEventSink?

    /// 註冊外接 FlutterViewController 上的 GeneratedPlugin（由 AppDelegate 注入）
    public static var registerGeneratedPlugin: ((FlutterViewController) -> Void)?
    /// 外接引擎：主畫面 → 外接畫面的參數 EventChannel
    public static var receiveParameters: FlutterEventChannel?
    /// 外接引擎：外接畫面 → 主畫面的參數 MethodChannel
    public static var sendParameters: FlutterMethodChannel?
    /// 外接螢幕上的 UIWindow
    public static var externalWindow: UIWindow?
    /// 外接畫面專用的 FlutterEngine
    public static var externalEngine: FlutterEngine?
    /// The external engine's view controller. It is created with the engine, so the host's
    /// plugins are registered before the engine's Dart code runs, and reused when a window
    /// is attached.
    static var externalViewController: FlutterViewController?

    /// Dart `connect` 尚未回傳時暫存的 FlutterResult（等待外接 UIScene 就緒）
    static var pendingConnectResult: FlutterResult?
    /// 待連接外接畫面的初始 route 名稱
    static var pendingRouteName: String = "externalView"
    /// connect 逾時工作項目（避免永久卡住）
    static var pendingConnectTimeout: DispatchWorkItem?
    /// The delayed plug-state report after a session ended without the app asking for it.
    static var stillAttachedReport: DispatchWorkItem?

    /// iOS 27+ 的 scene accessory 註冊物件（系統據此呈現外接內容）
    static var sceneAccessoryRegistration: AnyObject?
    /// 目前註冊 scene accessory 的主畫面 ViewController
    static var accessoryHostViewController: UIViewController?

    public static func register(with registrar: FlutterPluginRegistrar) {
        // 監聽外接螢幕插拔狀態
        let onDisplayChange = FlutterEventChannel(
            name: "monitorStateListener",
            binaryMessenger: registrar.messenger()
        )
        onDisplayChange.setStreamHandler(MainViewHandler())

        // 控制連接／斷開／傳參等 method
        let connect = FlutterMethodChannel(
            name: "displayController",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(ExternalDisplayPlugin(), channel: connect)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getScreen":
            // 回傳目前可用螢幕資訊
            result(Self.screenInfos())

        case "connect":
            // 連接到外接螢幕並啟動外接 Flutter 內容
            Self.connect(call: call, result: result)

        case "disconnect":
            // 主動斷開外接畫面
            result(Self.disconnect())

        case "waitingTransferParametersReady":
            // 等待外接畫面參數通道就緒
            Self.waitingTransferParametersReady(result: result)

        case "sendParameters":
            // 主畫面 → 外接畫面傳參
            if Self.externalViewEvents != nil {
                Self.externalViewEvents?(call.arguments)
                result(true)
            } else {
                result(false)
            }

        default:
            result(false)
        }
    }

    // MARK: - Connect / Disconnect

    /// 連接外接螢幕：iOS 27+ 走 UISceneAccessory，舊版走 UIScreen
    static func connect(call: FlutterMethodCall, result: @escaping FlutterResult) {
        // Mac 上的 iOS App 不支援外接顯示
        if #available(iOS 14.0, *), ProcessInfo.processInfo.isiOSAppOnMac {
            result(false)
            return
        }

        // The app acts itself: drop a pending "still attached" report.
        cancelStillAttachedReport()

        let args = call.arguments as? [String: Any]
        let routeName = (args?["routeName"] as? String) ?? "externalView"
        pendingRouteName = routeName

        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            connectWithSceneAccessory(routeName: routeName, result: result)
        } else {
            connectWithLegacyScreen(routeName: routeName, result: result)
        }
        #else
        connectWithLegacyScreen(routeName: routeName, result: result)
        #endif
    }

    /// 斷開外接畫面並清理資源
    static func disconnect() -> Bool {
        // A pending "still attached" report is about a session that had already ended: keep
        // it. A live session ended here is never reported (its scene finds no session).
        tearDownExternalSession(notifyUnplug: false)
        // Answer a connect still waiting for its scene instead of dropping it.
        completePendingConnect(false)
        // Disable only now: a scene disconnect delivered from the setter must find the
        // session gone already, or it would count as one the app did not end.
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            // 停用 scene accessory，讓系統收回外接 scene
            if let registration = sceneAccessoryRegistration as? UISceneAccessoryRegistration {
                registration.isEnabled = false
            }
        }
        #endif
        return true
    }

    /// A session ended without disconnect() or connect() asking for it (scene or screen
    /// event). Report `false` now and, once UIKit has settled, `true` if an external display
    /// is still attached, so the app can connect again. The plugin never reconnects itself.
    static func reportSessionEnded() {
        mainViewEvents?(false)
        scheduleStillAttachedReport()
    }

    /// Sends `true` one second from now if an external display is attached then. On a real
    /// unplug the scene can end a few milliseconds before UIKit drops the screen, so the
    /// plug state is read after that, never in the disconnect callback itself.
    static func scheduleStillAttachedReport() {
        cancelStillAttachedReport()
        let report = DispatchWorkItem {
            stillAttachedReport = nil
            if isStillAttachedForReport() {
                mainViewEvents?(true)
            }
        }
        stillAttachedReport = report
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: report)
    }

    /// What the delayed report counts as "still attached": a display a connect can use now.
    static func isStillAttachedForReport() -> Bool {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            return isExternalDisplayConnected()
        }
        #endif
        // Below iOS 27 a connect attaches to the declared scene. Until it is back there is
        // nothing to attach to, and its own willConnect reports `true` when it returns: a
        // `true` now would make Dart drop that later one.
        if hostDeclaresExternalDisplayScene() {
            return findExternalDisplayScene() != nil
        }
        return isExternalDisplayConnected()
    }

    static func cancelStillAttachedReport() {
        stillAttachedReport?.cancel()
        stillAttachedReport = nil
    }

    /// A UIScreen disconnect destroyed the engine of a connect still waiting for its scene:
    /// answer that connect now instead of at its 10 second timeout.
    static func failPendingConnectAfterScreenLoss() {
        guard pendingConnectResult != nil else { return }
        #if compiler(>=6.4)
        if #available(iOS 27.0, *),
           let registration = sceneAccessoryRegistration as? UISceneAccessoryRegistration {
            // As the connect timeout does.
            registration.isEnabled = false
        }
        #endif
        completePendingConnect(false)
    }

    // MARK: - iOS 27+ UISceneAccessory

    // UISceneAccessory ships with the iOS 27 SDK (Xcode 27, Swift 6.4). @available is
    // checked at run time only, so older compilers must not see this section at all;
    // they build the UIScreen path below.
    #if compiler(>=6.4)
    /// iOS 27+：透過 UISceneAccessory 啟用外接非互動 scene
    @available(iOS 27.0, *)
    static func connectWithSceneAccessory(routeName: String, result: @escaping FlutterResult) {
        guard let host = findMainFlutterViewController() else {
            result(false)
            return
        }

        ensureSceneAccessoryRegistered(on: host)

        guard let registration = sceneAccessoryRegistration as? UISceneAccessoryRegistration else {
            result(false)
            return
        }
        // 優先用 registration.isAvailable；模擬器／過渡環境可退回 UIScreen 判斷
        guard registration.isAvailable || UIScreen.screens.count > 1 else {
            result(false)
            return
        }

        // 開始新連線前先清掉舊 session
        tearDownExternalSession(notifyUnplug: false)

        // A previous connect may still be waiting: answer it before replacing it.
        completePendingConnect(false)
        pendingConnectResult = result
        prepareExternalFlutterContent(routeName: routeName)

        // 啟用 accessory 後，系統會非同步連上外接 scene
        registration.isEnabled = true

        // 若 scene 已存在（例如已插著），直接掛載內容
        if let windowScene = findExternalWindowScene() {
            attachExternalContent(to: windowScene)
            return
        }

        // 啟用 accessory 後 scene 連線是非同步的，設定逾時避免永久等待
        pendingConnectTimeout?.cancel()
        let timeout = DispatchWorkItem {
            guard let pending = pendingConnectResult else { return }
            pendingConnectResult = nil
            tearDownExternalSession(notifyUnplug: false)
            registration.isEnabled = false
            pending(false)
        }
        pendingConnectTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: timeout)
    }

    /// 確保主畫面上已註冊 externalNonInteractive 的 scene accessory
    @available(iOS 27.0, *)
    static func ensureSceneAccessoryRegistered(on host: UIViewController) {
        // 同一個 host 已註冊過就不用重做
        if sceneAccessoryRegistration != nil, accessoryHostViewController === host {
            return
        }

        // host 換了就先從舊 host 解除註冊
        if let existing = sceneAccessoryRegistration as? UISceneAccessoryRegistration,
           let previousHost = accessoryHostViewController {
            previousHost.unregisterSceneAccessory(existing)
            sceneAccessoryRegistration = nil
            accessoryHostViewController = nil
        }

        // role 由 externalNonInteractive 決定，只需指定 scene delegate
        let configuration = UISceneConfiguration()
        configuration.delegateClass = ExternalDisplaySceneDelegate.self

        let accessory = UISceneAccessory.externalNonInteractive(sceneConfiguration: configuration)
        let registration = host.registerSceneAccessory(accessory)
        registration.isEnabled = false
        sceneAccessoryRegistration = registration
        accessoryHostViewController = host
    }

    /// 由 [ExternalDisplaySceneDelegate] 在外接 scene 即將連上時呼叫
    @available(iOS 27.0, *)
    static func handleExternalSceneWillConnect(_ scene: UIWindowScene) {
        attachExternalContent(to: scene)
        // 通知主畫面：外接螢幕已連上
        mainViewEvents?(true)
    }

    /// 外接 scene 斷開時清理，並停用 accessory
    /// `sceneWindow` is the window the scene's delegate holds: only that session ends here.
    /// After disconnect() or a replacing connect() it is gone already, and nothing is reported.
    @available(iOS 27.0, *)
    static func handleExternalSceneDidDisconnect(sceneWindow: UIWindow?) {
        let sessionEnded = sceneWindow != nil && sceneWindow === externalWindow
        if sessionEnded {
            tearDownExternalSession(notifyUnplug: false)
        }
        // A connect waiting for its scene keeps the accessory enabled.
        if pendingConnectResult == nil,
           let registration = sceneAccessoryRegistration as? UISceneAccessoryRegistration {
            registration.isEnabled = false
        }
        if sessionEnded {
            reportSessionEnded()
        }
    }
    #endif

    /// 將外接 Flutter 內容掛到指定的 UIWindowScene
    /// Shared by the iOS 27 scene accessory and the window scene path below iOS 27.
    static func attachExternalContent(to windowScene: UIWindowScene) {
        // 已有外接 window：只完成 pending connect（回傳尺寸）
        if externalWindow != nil {
            let size = windowScene.screen.bounds.size
            completePendingConnect(["height": size.height, "width": size.width])
            return
        }

        // 沒有進行中的 connect、也沒有既有引擎時不處理
        guard pendingConnectResult != nil || externalEngine != nil else {
            return
        }

        if externalEngine == nil {
            prepareExternalFlutterContent(routeName: pendingRouteName)
        }

        // Created with the engine, plugins already registered (prepareExternalFlutterContent).
        guard let flutterViewController = externalViewController else {
            completePendingConnect(false)
            return
        }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = flutterViewController
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            window.makeKeyAndVisible()
        } else {
            // Below iOS 27, as the UIScreen path does: shown, never the key window.
            window.isHidden = false
        }
        #else
        window.isHidden = false
        #endif
        externalWindow = window

        // 讓 scene delegate 持有 window，避免被釋放
        if let sceneDelegate = windowScene.delegate as? ExternalDisplaySceneDelegate {
            sceneDelegate.window = window
        }

        let size = windowScene.screen.bounds.size
        completePendingConnect(["height": size.height, "width": size.width])
    }

    #if compiler(>=6.4)
    /// 在已連線 scenes 中尋找外接非互動 WindowScene
    @available(iOS 27.0, *)
    static func findExternalWindowScene() -> UIWindowScene? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if windowScene.session.role == .windowExternalDisplayNonInteractive {
                return windowScene
            }
        }
        return nil
    }
    #endif

    // MARK: - Legacy UIScreen path (iOS < 27)

    /// iOS 27 以前：直接用 UIScreen.screens[1] 建立外接 UIWindow
    static func connectWithLegacyScreen(routeName: String, result: @escaping FlutterResult) {
        // Under the UIScene life cycle a window is shown only through a window scene: use
        // the external display's scene when the system has connected one.
        if let windowScene = findExternalDisplayScene() {
            connectWithWindowScene(windowScene, routeName: routeName, result: result)
            return
        }

        guard UIScreen.screens.count > 1 else {
            result(false)
            return
        }

        // The host assigned ExternalDisplaySceneDelegate to the external display role, so the
        // system connects a scene for this screen, possibly after the plug event: wait for it.
        if hostDeclaresExternalDisplayScene() {
            connectWithWindowScene(nil, routeName: routeName, result: result)
            return
        }

        tearDownExternalSession(notifyUnplug: false)

        let externalScreen = UIScreen.screens[1]
        // 選最高解析度模式
        let mode = externalScreen.availableModes.last
        externalScreen.currentMode = mode
        guard let mode else {
            result(false)
            return
        }

        var frame = CGRect.zero
        frame.size = mode.size

        prepareExternalFlutterContent(routeName: routeName)
        guard let flutterViewController = externalViewController else {
            result(false)
            return
        }

        flutterViewController.view.frame = frame

        let window = UIWindow(frame: frame)
        window.rootViewController = flutterViewController
        window.screen = externalScreen
        window.isHidden = false
        externalWindow = window

        // Under the UIScene life cycle a window without a window scene appears on no screen
        // (UIWindow.windowScene), and Flutter takes its screen and scale from that scene, so
        // report a size only when the window really landed on the external screen.
        if sceneManifest != nil, window.windowScene?.screen !== externalScreen {
            tearDownExternalSession(notifyUnplug: false)
            result(false)
            return
        }

        result(["height": mode.size.height, "width": mode.size.width])
    }

    // MARK: - Window scene path below iOS 27

    /// Starts the external content and attaches it to `windowScene`, or, when it is nil,
    /// waits up to 10 seconds for ExternalDisplaySceneDelegate to deliver the scene.
    static func connectWithWindowScene(
        _ windowScene: UIWindowScene?,
        routeName: String,
        result: @escaping FlutterResult
    ) {
        tearDownExternalSession(notifyUnplug: false)

        // A previous connect may still be waiting: answer it before replacing it.
        completePendingConnect(false)
        pendingConnectResult = result
        prepareExternalFlutterContent(routeName: routeName)

        if let windowScene {
            attachExternalContent(to: windowScene)
            return
        }

        let timeout = DispatchWorkItem {
            guard let pending = pendingConnectResult else { return }
            pendingConnectResult = nil
            tearDownExternalSession(notifyUnplug: false)
            pending(false)
        }
        pendingConnectTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: timeout)
    }

    /// Called by ExternalDisplaySceneDelegate below iOS 27: the system connected the scene the
    /// host declared for the external display.
    static func handleDeclaredSceneWillConnect(_ scene: UIWindowScene) {
        // Attach at once when a connect is waiting for this scene.
        if pendingConnectResult != nil {
            attachExternalContent(to: scene)
        }
        mainViewEvents?(true)
    }

    /// Called by ExternalDisplaySceneDelegate below iOS 27 with the window it holds.
    static func handleDeclaredSceneDidDisconnect(sceneWindow: UIWindow?) {
        // Only the session shown on this scene ends here. When the UIScreen disconnect
        // observer ran first it has already done so, and a late disconnect of an older scene
        // must not mark a live session unplugged: report nothing then.
        guard let sceneWindow, sceneWindow === externalWindow else { return }
        tearDownExternalSession(notifyUnplug: false)
        reportSessionEnded()
    }

    /// The host's UIApplicationSceneManifest; nil when it does not use the UIScene life cycle.
    static var sceneManifest: [String: Any]? {
        Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any]
    }

    /// The session role of a non-interactive external display on this iOS version.
    static var externalDisplayRole: UISceneSession.Role {
        if #available(iOS 16.0, *) {
            return .windowExternalDisplayNonInteractive
        }
        return .windowExternalDisplay
    }

    /// Whether the host's Info.plist assigns ExternalDisplaySceneDelegate to the external
    /// display role.
    static func hostDeclaresExternalDisplayScene() -> Bool {
        guard let configurations = sceneManifest?["UISceneConfigurations"] as? [String: Any],
              let entries = configurations[externalDisplayRole.rawValue] as? [[String: Any]] else {
            return false
        }
        let delegateName = NSStringFromClass(ExternalDisplaySceneDelegate.self)
        return entries.contains { ($0["UISceneDelegateClassName"] as? String) == delegateName }
    }

    /// A connected window scene of the external display, under the UIScene life cycle only.
    /// Never the app's own scene, which Stage Manager can also place on the external screen.
    static func findExternalDisplayScene() -> UIWindowScene? {
        // Without the UIScene life cycle the UIScreen path stays exactly as it was.
        guard sceneManifest != nil else { return nil }

        let externalScreens = UIScreen.screens.dropFirst()
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.session.role != .windowApplication else { continue }
            if windowScene.session.role == externalDisplayRole
                || externalScreens.contains(where: { $0 === windowScene.screen }) {
                return windowScene
            }
        }
        return nil
    }

    // MARK: - Shared helpers

    /// 建立外接 FlutterEngine，並設定雙向參數通道
    static func prepareExternalFlutterContent(routeName: String) {
        let flutterEngine = FlutterEngine(name: "external_display")
        // 使用獨立 entrypoint 啟動外接畫面
        flutterEngine.run(withEntrypoint: "externalDisplayMain", initialRoute: routeName)
        externalEngine = flutterEngine

        // 主畫面 → 外接畫面
        receiveParameters = FlutterEventChannel(
            name: "receiveParametersListener",
            binaryMessenger: flutterEngine.binaryMessenger
        )
        receiveParameters?.setStreamHandler(ExternalViewHandler())

        // 外接畫面 → 主畫面
        sendParameters = FlutterMethodChannel(
            name: "sendParameters",
            binaryMessenger: flutterEngine.binaryMessenger
        )
        flutterEngine.registrar(forPlugin: "ExternalDisplaySendParameters")?
            .addMethodCallDelegate(ExternalDisplaySendParameters(), channel: sendParameters!)

        // Register the host's plugins now, in the same main-thread turn as `run`. The engine
        // runs Dart on this thread and starts the entrypoint from a later task, so the first
        // plugin call of `externalDisplayMain` finds its handler even when the window is
        // attached much later (iOS 27 scene accessory, scene delegate below iOS 27).
        let flutterViewController = FlutterViewController(
            engine: flutterEngine,
            nibName: nil,
            bundle: nil
        )
        registerGeneratedPlugin?(flutterViewController)
        externalViewController = flutterViewController
    }

    /// 拆除外接 session（window、通道、引擎）
    /// - Parameter notifyUnplug: 是否通知主畫面「已拔除」
    /// - Returns: whether there was a session (a window or a running engine) to tear down.
    @discardableResult
    static func tearDownExternalSession(notifyUnplug: Bool) -> Bool {
        let hadSession = externalWindow != nil || externalEngine != nil

        // The scene delegate holds the window too: let it go with the session.
        if let window = externalWindow,
           let sceneDelegate = window.windowScene?.delegate as? ExternalDisplaySceneDelegate,
           sceneDelegate.window === window {
            sceneDelegate.window = nil
        }
        externalWindow?.isHidden = true
        externalWindow?.rootViewController = nil
        externalWindow = nil
        externalViewController = nil

        receiveParameters?.setStreamHandler(nil)
        receiveParameters = nil
        sendParameters?.setMethodCallHandler(nil)
        sendParameters = nil
        externalViewEvents = nil

        if let engine = externalEngine {
            engine.destroyContext()
            externalEngine = nil
        }

        if notifyUnplug {
            mainViewEvents?(false)
        }
        return hadSession
    }

    /// 完成（或取消逾時後）回傳 pending 的 connect result
    static func completePendingConnect(_ value: Any) {
        pendingConnectTimeout?.cancel()
        pendingConnectTimeout = nil
        guard let pending = pendingConnectResult else { return }
        pendingConnectResult = nil
        pending(value)
    }

    /// 取得目前螢幕／scene 尺寸與 role 字串列表（供除錯用）
    static func screenInfos() -> [String] {
        if #available(iOS 27.0, *) {
            var infos = [String]()
            var index = 0
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                let size = windowScene.screen.bounds.size
                let role = windowScene.session.role.rawValue
                infos.append(
                    "\(index). [\(Int(size.width))x\(Int(size.height))] (\(role))"
                )
                index += 1
            }
            if !infos.isEmpty {
                return infos
            }
        }

        return UIScreen.screens.enumerated().map { i, screen in
            "\(i). [\(Int(screen.nativeBounds.width))x\(Int(screen.nativeBounds.height))]"
        }
    }

    /// 尋找主畫面的 FlutterViewController（用來註冊 scene accessory）
    static func findMainFlutterViewController() -> FlutterViewController? {
        for scene in UIApplication.shared.connectedScenes {
            // Only app scenes: the external display scene hosts the external engine's view.
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.session.role == .windowApplication else { continue }
            for window in windowScene.windows where window !== externalWindow {
                if let flutter = window.rootViewController as? FlutterViewController {
                    return flutter
                }
                if let flutter = findFlutterViewController(in: window.rootViewController) {
                    return flutter
                }
            }
        }

        // 相容舊式 AppDelegate.window
        if let root = UIApplication.shared.delegate?.window??.rootViewController as? FlutterViewController {
            return root
        }
        return findFlutterViewController(in: UIApplication.shared.delegate?.window??.rootViewController)
    }

    /// 遞迴在 child / presented VC 中尋找 FlutterViewController
    static func findFlutterViewController(in root: UIViewController?) -> FlutterViewController? {
        guard let root else { return nil }
        if let flutter = root as? FlutterViewController {
            return flutter
        }
        for child in root.children {
            if let flutter = findFlutterViewController(in: child) {
                return flutter
            }
        }
        return findFlutterViewController(in: root.presentedViewController)
    }

    /// 判斷目前是否有外接螢幕可用／已連線
    static func isExternalDisplayConnected() -> Bool {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            if let registration = sceneAccessoryRegistration as? UISceneAccessoryRegistration,
               registration.isAvailable {
                return true
            }
            if findExternalWindowScene() != nil {
                return true
            }
        }
        #endif
        return UIScreen.screens.count > 1
    }

    /// 等待外接畫面參數 EventChannel 就緒（最多約 10 秒）
    static func waitingTransferParametersReady(result: @escaping FlutterResult) {
        let sendFail = DispatchWorkItem {
            result(false)
            connectReturn = nil
        }

        func returnResolution() {
            sendFail.cancel()
            result(true)
            connectReturn = nil
        }
        connectReturn = returnResolution

        if externalViewEvents != nil {
            // 外接畫面已在聽，立刻回傳成功
            connectReturn?()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: sendFail)
        }
    }
}

// MARK: - External scene delegate

/// 供 [UISceneAccessory.externalNonInteractive] 使用的 Scene Delegate
/// Below iOS 27 a host can assign it to the external display role in its Info.plist.
@objc(ExternalDisplaySceneDelegate)
public class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    public var window: UIWindow?

    public func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else {
            return
        }
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            // 外接 scene 連上：掛載 Flutter 內容
            ExternalDisplayPlugin.handleExternalSceneWillConnect(windowScene)
        } else {
            // Below iOS 27 this scene comes from the host's Info.plist scene configuration.
            ExternalDisplayPlugin.handleDeclaredSceneWillConnect(windowScene)
        }
        #else
        ExternalDisplayPlugin.handleDeclaredSceneWillConnect(windowScene)
        #endif
    }

    public func sceneDidDisconnect(_ scene: UIScene) {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            // 外接 scene 斷開：清理 session
            ExternalDisplayPlugin.handleExternalSceneDidDisconnect(sceneWindow: window)
        } else {
            ExternalDisplayPlugin.handleDeclaredSceneDidDisconnect(sceneWindow: window)
        }
        #else
        ExternalDisplayPlugin.handleDeclaredSceneDidDisconnect(sceneWindow: window)
        #endif
        window = nil
    }
}

// MARK: - Parameter bridge

/// 外接畫面透過此 plugin 把參數送回主畫面
public class ExternalDisplaySendParameters: NSObject, FlutterPlugin {
    public static func register(with registrar: any FlutterPluginRegistrar) {}

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        // Without a listening main view the message is not delivered: reply false.
        guard let events = ExternalDisplayPlugin.mainViewEvents else {
            result(false)
            return
        }
        events(call.arguments)
        result(true)
    }
}

// MARK: - Main view stream

/// 主畫面監聽外接螢幕插拔狀態的 EventChannel handler
public class MainViewHandler: NSObject, FlutterStreamHandler {
    var didConnectObserver: NSObjectProtocol?
    var didDisconnectObserver: NSObjectProtocol?

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        ExternalDisplayPlugin.mainViewEvents = events

        // Mac 上的 iOS App 不處理外接顯示
        if #available(iOS 14.0, *), ProcessInfo.processInfo.isiOSAppOnMac {
            return nil
        }

        // 提早註冊 scene accessory，讓 iOS 27+ 的 isAvailable 能反映插拔狀態
        #if compiler(>=6.4)
        if #available(iOS 27.0, *),
           let host = ExternalDisplayPlugin.findMainFlutterViewController() {
            ExternalDisplayPlugin.ensureSceneAccessoryRegistered(on: host)
        }
        #endif

        // 若當下已連線，先推一次 true
        if ExternalDisplayPlugin.isExternalDisplayConnected() {
            events(true)
        }

        // 舊版 UIScreen 插拔通知（iOS 27 以前仍有效；之後 scene 路徑另有處理）
        didConnectObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.didConnectNotification,
            object: nil,
            queue: .main
        ) { _ in
            events(true)
        }

        didDisconnectObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.didDisconnectNotification,
            object: nil,
            queue: .main
        ) { _ in
            let sessionEnded = ExternalDisplayPlugin.tearDownExternalSession(notifyUnplug: false)
            ExternalDisplayPlugin.failPendingConnectAfterScreenLoss()
            events(false)
            // Another external display may still be attached: report it as for a scene. A
            // pending report restarts, so it is read a settle time after the last event.
            if sessionEnded || ExternalDisplayPlugin.stillAttachedReport != nil {
                ExternalDisplayPlugin.scheduleStillAttachedReport()
            }
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        if let didConnectObserver {
            NotificationCenter.default.removeObserver(didConnectObserver)
        }
        if let didDisconnectObserver {
            NotificationCenter.default.removeObserver(didDisconnectObserver)
        }
        self.didConnectObserver = nil
        self.didDisconnectObserver = nil
        ExternalDisplayPlugin.mainViewEvents = nil
        return nil
    }
}

// MARK: - External view stream

/// 外接畫面接收參數的 EventChannel handler；開始 listen 時代表參數通道已就緒
public class ExternalViewHandler: NSObject, FlutterStreamHandler {
    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        ExternalDisplayPlugin.externalViewEvents = events
        // 通知主畫面：傳參通道已可使用
        ExternalDisplayPlugin.connectReturn?()
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        ExternalDisplayPlugin.externalViewEvents = nil
        return nil
    }
}
