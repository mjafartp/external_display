## 0.6.0-lithos.1

Fork build (`mjafartp/external_display`, branch `integration`), not an upstream release. It combines the changes proposed upstream as separate pull requests.

### Added
- `getDisplays()` returns an `ExternalDisplayInfo` for every display: `id`, `name`, `width`, `height`, `isPrimary` and `hasTouch` (`true`, `false`, or `null` when the platform cannot tell). On Android the touch answer is per display from Android 12L (API 32); iOS reports `false` for external screens; macOS reports `null`.
- `ExternalDisplay.isConnected`: `true` while the instance that called `connect()` has a resolution.

### Fixed
- **Android**: `connect` no longer destroys and restarts the external view when it is already showing on the same display.
- **Android**: the external window can no longer be closed with the Back key. When Android or the host Activity closes it, or its display is removed, the session is released and the app receives "unplugged" followed by the current plug state.
- **Android**: the display listener is registered once per engine and removed with it. A `connect` that fails releases everything it created and returns `false`.
- **Android**: the external display is picked from the presentation displays first (with the previous behaviour as fallback), and the external view is built with that display's own context, so it uses the right density.
- **Android**: platform views on the external display should work again on Flutter 3.38 and newer: only the engine's platform-views delegator installs their channel handler, and the plugin now attaches it (from reading the engine source; not yet run with a platform view).
- **Android**: every `waitingTransferParametersReady` call is answered exactly once, each route keeps its own parameter stream, and `disconnect` returns `true` only when a session was closed.
- **Dart**: several `ExternalDisplay` or `TransferParameters` instances now share one native subscription; creating or disposing one no longer cuts the others off.
- **Dart**: a listener that throws or removes itself no longer stops the remaining listeners; an unplug clears `resolution`.
- **Dart**: on platforms without a native implementation (Windows, Linux, web) the classes no longer report an error at construction; methods return `false` or an empty list.
- **iOS / macOS**: the parameter stream of the external view keeps working after an instance is disposed (the `MissingPluginException … receiveParametersListener` error).
- **iOS**: a `connect()` that is still waiting is answered with `false` when `disconnect()` or another `connect()` arrives, instead of never completing; the main view controller lookup can no longer pick the external one.
- **iOS**: the plugin compiles with Xcode versions older than 27 (the iOS 27 scene code is behind a compiler check; not yet built on such an Xcode).
- **macOS**: `createWindow(fullscreen: true)` on a window that is already fullscreen no longer toggles it out of fullscreen.
- `TransferParameters.sendParameters` returns `false` when the main view is not listening (all platforms).

### Changed
- **Android**: the manifest `package` attribute (ignored by current Android Gradle Plugin versions) and the unused `mockito-core` test dependency are removed.
- **Android**: `getScreen` prints each display's size as the physical size of its current mode, the size `connect` reports; it printed `display.width` / `display.height` before, which follow rotation.
- **Android** (Kotlin only, not visible from Dart): `ExternalDisplayPlugin.connectReturn` is removed, `externalViewEvents` is no longer public, and the `ExternalViewHandler` constructor also takes the route name and the engine.

## 0.5.3

### Fixed
- **Android**: Parse MethodChannel arguments as a `Map` instead of `JSONObject("${call.arguments}")`, which could fail at runtime because `Map.toString()` is not valid JSON.

### Changed
- Android plugin package/namespace renamed from `com.example.external_display` to `com.gavinfu.external_display`.
- `homepage` now points to the repository URL; iOS/macOS podspec metadata updated to match package version `0.5.3`.
- Bumps `flutter_lints` to `^6.0.0`.

## 0.5.2

### Fixed
- **macOS**: Exiting fullscreen on an external window no longer crashes the app (`Could not create the embedder backing store`). The main-window close observer now watches only the primary Flutter window, so AppKit transient windows created during fullscreen transitions no longer tear down the external `FlutterEngine`.

### Changed
- macOS external windows use a standard titled style mask with `fullScreenPrimary` collection behavior, and session teardown now calls `shutDownEngine()` after detaching the view.

## 0.5.1

### Added
- iOS Swift Package Manager support (`ios/external_display/Package.swift`).

### Changed
- Dart API return types are now explicit `Future<bool>` for `connect`, `disconnect`, `createWindow`, `destroyWindow`, `waitingTransferParametersReady`, and `sendParameters`.
- Status listener type is `void Function(bool connecting)`; parameter listeners use dedicated typedefs.
- Android/macOS tear down external sessions on unplug, reconnect, disconnect, and window close; external-view `sendParameters` completes its MethodChannel `result` on all platforms.
- Migrates Android plugin to built-in Kotlin (`kotlin.compilerOptions`) and raises the minimum Flutter SDK to 3.44 / Dart 3.12.

## 0.5.0

### Added
- **iOS 27 UISceneAccessory support**: On iOS 27+, external display content uses `UISceneAccessory.externalNonInteractive` and `ExternalDisplaySceneDelegate` instead of the legacy `UIWindow.screen` path.
- Example app adopts the Flutter UIScene lifecycle (`UIApplicationSceneManifest` + `FlutterPluginRegistrant`).

### Changed
- iOS `disconnect` and scene teardown now destroy the external `FlutterEngine` to avoid leaking a second Flutter runtime.
- External-view `sendParameters` now completes its MethodChannel `result`.

## 0.4.2

### Fixed
- Fixed abnormal display resolution issues after repeatedly connecting/disconnecting different external displays.

## 0.4.0

### Added
- **macOS support**: Now uses `createWindow` to create new windows for display projection on macOS.

### Changed
- **Simplified initialization**:  
  No longer need to explicitly declare:
  ```dart
  ExternalDisplay externalDisplay = ExternalDisplay();
  TransferParameters transferParameters = TransferParameters();
  ```

## 0.3.1

### Fixed
- Fixed an issue where popup dialogs from other Flutter plugins would incorrectly appear on external displays.

## 0.3.0

### Added
- **Bidirectional parameter transfer** between the main view and external display view.

## 0.2.1

### Fixed
- Disabled the plugin when iOS apps run on macOS to prevent the external display from overlapping the primary app window.

## 0.2.0

### Added
- Initial **Flutter plugin support** for external displays.

## 0.1.2

### Added
- `waitingTransferParametersReady` function to ensure parameter delivery synchronization after connecting an external display.  
  - Required when transferring parameters immediately upon connection.