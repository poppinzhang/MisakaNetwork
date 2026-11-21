#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <shellapi.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {
constexpr UINT kNotificationCallback = WM_APP + 1;

const std::string* NotificationString(const flutter::EncodableMap& args, const char* key) {
  const auto entry = args.find(flutter::EncodableValue(key));
  if (entry == args.end()) return nullptr;
  const auto* value = std::get_if<std::string>(&entry->second);
  return value && !value->empty() ? value : nullptr;
}

template <size_t N>
bool CopyNotificationText(const flutter::EncodableMap& args, const char* key,
                          wchar_t (&out)[N]) {
  const auto* value = NotificationString(args, key);
  return value && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value->c_str(),
                                      -1, out, static_cast<int>(N)) > 0;
}

void DeleteNotificationIcon(HWND window, UINT id) {
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = window;
  icon.uID = id;
  Shell_NotifyIconW(NIM_DELETE, &icon);
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterNotifications();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::RegisterNotifications() {
  flutter::MethodChannel<flutter::EncodableValue> channel(
      flutter_controller_->engine()->messenger(), "misaka/notifications",
      &flutter::StandardMethodCodec::GetInstance());
  channel.SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "requestPermission") {
      // Shell notifications have no per-application permission prompt.
      result->Success(flutter::EncodableValue(true));
      return;
    }
    if (call.method_name() != "showSuccess") {
      result->NotImplemented();
      return;
    }
    NOTIFYICONDATAW icon{};
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (!args || !NotificationString(*args, "id") ||
        !CopyNotificationText(*args, "title", icon.szInfoTitle) ||
        !CopyNotificationText(*args, "body", icon.szInfo)) {
      result->Error("invalid_arguments", "Invalid notification.");
      return;
    }

    // Each pending order has its own temporary icon so simultaneous
    // notifications are queued by Explorer instead of replacing one another.
    icon.cbSize = sizeof(icon);
    icon.hWnd = GetHandle();
    icon.uID = next_notification_id_++;
    icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_INFO | NIF_TIP;
    icon.uCallbackMessage = kNotificationCallback;
    icon.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
    wcscpy_s(icon.szTip, L"LastOrder");
    icon.dwInfoFlags = NIIF_USER | NIIF_RESPECT_QUIET_TIME;
    icon.hBalloonIcon = icon.hIcon;
    if (!Shell_NotifyIconW(NIM_ADD, &icon)) {
      result->Error("notification_error", "Windows could not submit the notification.");
      return;
    }
    // Version 3 callbacks carry the full 32-bit icon ID in wParam.
    icon.uVersion = NOTIFYICON_VERSION;
    if (!Shell_NotifyIconW(NIM_SETVERSION, &icon)) {
      DeleteNotificationIcon(icon.hWnd, icon.uID);
      result->Error("notification_error", "Windows could not configure the notification.");
      return;
    }
    active_notification_ids_.insert(icon.uID);
    result->Success(flutter::EncodableValue(true));
  });
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_DESTROY:
      for (const auto id : active_notification_ids_) {
        DeleteNotificationIcon(hwnd, id);
      }
      active_notification_ids_.clear();
      break;
    case kNotificationCallback: {
      const auto id = static_cast<UINT>(wparam);
      if (lparam == NIN_BALLOONHIDE || lparam == NIN_BALLOONTIMEOUT ||
          lparam == NIN_BALLOONUSERCLICK) {
        if (active_notification_ids_.erase(id)) {
          DeleteNotificationIcon(hwnd, id);
          if (lparam == NIN_BALLOONUSERCLICK) {
            if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
            SetForegroundWindow(hwnd);
          }
        }
      }
      return 0;
    }
    case WM_GETMINMAXINFO: {
      const UINT dpi = FlutterDesktopGetDpiForMonitor(
          ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST));
      auto limits = reinterpret_cast<MINMAXINFO*>(lparam);
      limits->ptMinTrackSize.x = ::MulDiv(800, dpi, 96);
      limits->ptMinTrackSize.y = ::MulDiv(640, dpi, 96);
      return 0;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
