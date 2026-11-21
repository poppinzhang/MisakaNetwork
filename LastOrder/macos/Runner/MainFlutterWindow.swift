import Cocoa
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow {
  private let notifications = SuccessNotifications()

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(NSRect(x: windowFrame.origin.x, y: windowFrame.origin.y, width: 1280, height: 860), display: true)
    self.minSize = NSSize(width: 800, height: 640)
    self.title = "LastOrder"

    RegisterGeneratedPlugins(registry: flutterViewController)
    notifications.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

private final class SuccessNotifications: NSObject, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()

  func register(with messenger: FlutterBinaryMessenger) {
    center.delegate = self
    let channel = FlutterMethodChannel(name: "misaka/notifications", binaryMessenger: messenger)
    channel.setMethodCallHandler { [self] call, result in
      switch call.method {
      case "requestPermission":
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
          self.finish(granted, error, result)
        }
      case "showSuccess":
        guard let args = call.arguments as? [String: Any],
              let id = args["id"] as? String, !id.isEmpty,
              let title = args["title"] as? String, !title.isEmpty,
              let body = args["body"] as? String, !body.isEmpty else {
          result(FlutterError(code: "invalid_arguments", message: "Invalid notification.", details: nil))
          return
        }
        center.getNotificationSettings { settings in
          guard [.authorized, .provisional].contains(settings.authorizationStatus) else {
            self.finish(false, nil, result)
            return
          }
          let content = UNMutableNotificationContent()
          content.title = title
          content.body = body
          content.sound = .default
          let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
          self.center.add(request) { error in
            self.finish(error == nil, error, result)
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func finish(_ value: Bool, _ error: Error?, _ result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      if error != nil {
        result(FlutterError(code: "notification_error", message: "Notification service failed.", details: nil))
      } else {
        result(value)
      }
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }
}
