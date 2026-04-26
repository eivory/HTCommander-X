import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Floor the window at a size where the desktop sidebar layout
    // still fits comfortably (the responsive breakpoint in
    // app.dart is 800 px; we add headroom for the VFO / status
    // columns and for title-bar chrome). Going narrower than this
    // overflows the communication pane and the navigation-bar
    // assertion in mobile mode can fire.
    self.contentMinSize = NSSize(width: 960, height: 640)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Register the HTCommander-X native audio plugin. Lives in
    // Runner/NativeAudioPlugin.swift; provides a low-latency
    // AVAudioEngine-backed mic capture with CoreAudio device selection.
    NativeAudioPlugin.register(
      with: flutterViewController.registrar(forPlugin: "NativeAudioPlugin"))

    // Native CoreBluetooth control of the Benshi UV-PRO.
    // Replaces the bendio Python subprocess for BLE; see
    // Runner/NativeBluetoothPlugin.swift.
    NativeBluetoothPlugin.register(
      with: flutterViewController.registrar(forPlugin: "NativeBluetoothPlugin"))

    // Phase 2: native RFCOMM audio (libsbc + IOBluetooth + AVAudioEngine).
    // See Runner/RfcommAudioPlugin.swift and
    // docs/Phase2-NativeAudio-Review.md.
    RfcommAudioPlugin.register(
      with: flutterViewController.registrar(forPlugin: "RfcommAudioPlugin"))

    super.awakeFromNib()
  }
}
