import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Register the HTCommander-X native audio plugin. Lives in
    // Runner/NativeAudioPlugin.swift; provides a low-latency
    // AVAudioEngine-backed mic capture with CoreAudio device selection.
    NativeAudioPlugin.register(
      with: flutterViewController.registrar(forPlugin: "NativeAudioPlugin"))

    super.awakeFromNib()
  }
}
