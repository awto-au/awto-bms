#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

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
  SetUpWindowChannel();
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

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

namespace {

// The window's DPI scale (physical px per logical px).
double ScaleFor(HWND hwnd) {
  return FlutterDesktopGetDpiForHWND(hwnd) / 96.0;
}

// A finite double from an EncodableValue holding an int or a double.
std::optional<double> AsDouble(const flutter::EncodableValue& v) {
  if (std::holds_alternative<double>(v)) return std::get<double>(v);
  if (std::holds_alternative<int32_t>(v)) return std::get<int32_t>(v);
  if (std::holds_alternative<int64_t>(v)) {
    return static_cast<double>(std::get<int64_t>(v));
  }
  return std::nullopt;
}

}  // namespace

// #68: the window's outer rect in LOGICAL px plus whether it is maximized.
// While maximized the rect reported is the RESTORED (normal) placement, so
// Dart keeps the size the user had before maximizing.
flutter::EncodableValue FlutterWindow::CurrentBounds() {
  HWND hwnd = GetHandle();
  flutter::EncodableMap map;
  if (!hwnd) return flutter::EncodableValue(map);
  const bool maximized = ::IsZoomed(hwnd) != 0;
  RECT r = {};
  if (maximized) {
    WINDOWPLACEMENT wp = {};
    wp.length = sizeof(wp);
    if (::GetWindowPlacement(hwnd, &wp)) {
      r = wp.rcNormalPosition;  // workspace coordinates; close enough
    }
  } else {
    ::GetWindowRect(hwnd, &r);
  }
  const double scale = ScaleFor(hwnd);
  map[flutter::EncodableValue("left")] = flutter::EncodableValue(r.left / scale);
  map[flutter::EncodableValue("top")] = flutter::EncodableValue(r.top / scale);
  map[flutter::EncodableValue("width")] =
      flutter::EncodableValue((r.right - r.left) / scale);
  map[flutter::EncodableValue("height")] =
      flutter::EncodableValue((r.bottom - r.top) / scale);
  map[flutter::EncodableValue("maximized")] = flutter::EncodableValue(maximized);
  return flutter::EncodableValue(map);
}

void FlutterWindow::NotifyBoundsChanged() {
  if (!window_channel_ || !GetHandle() || ::IsIconic(GetHandle())) return;
  window_channel_->InvokeMethod(
      "boundsChanged",
      std::make_unique<flutter::EncodableValue>(CurrentBounds()));
}

void FlutterWindow::SetUpWindowChannel() {
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "battery_reader/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HWND hwnd = GetHandle();
        if (!hwnd) {
          result->Error("no_window", "The window is gone");
          return;
        }
        const std::string& method = call.method_name();
        if (method == "getBounds") {
          result->Success(CurrentBounds());
        } else if (method == "maximize") {
          ::ShowWindow(hwnd, SW_MAXIMIZE);
          result->Success();
        } else if (method == "setBounds") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("bad_args", "setBounds needs a map");
            return;
          }
          auto get = [&](const char* key) -> std::optional<double> {
            auto it = args->find(flutter::EncodableValue(key));
            if (it == args->end()) return std::nullopt;
            return AsDouble(it->second);
          };
          const auto left = get("left"), top = get("top"),
                     width = get("width"), height = get("height");
          if (!left || !top || !width || !height) {
            result->Error("bad_args", "left/top/width/height required");
            return;
          }
          const double scale = ScaleFor(hwnd);
          RECT r;
          r.left = static_cast<LONG>(*left * scale);
          r.top = static_cast<LONG>(*top * scale);
          r.right = r.left + static_cast<LONG>(*width * scale);
          r.bottom = r.top + static_cast<LONG>(*height * scale);
          // Only a placement that is at least partly on a live monitor is
          // applied — a window last seen on an unplugged display stays where
          // the runner put it on first run.
          if (::MonitorFromRect(&r, MONITOR_DEFAULTTONULL) == nullptr) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          if (::IsZoomed(hwnd)) ::ShowWindow(hwnd, SW_RESTORE);
          ::SetWindowPos(hwnd, nullptr, r.left, r.top, r.right - r.left,
                         r.bottom - r.top, SWP_NOZORDER | SWP_NOACTIVATE);
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });
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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    // #68: report the placement to Dart after a drag / resize ends and on
    // maximize / restore (Dart debounces the saves).
    case WM_EXITSIZEMOVE:
      NotifyBoundsChanged();
      break;
    case WM_SIZE:
      if (wparam == SIZE_MAXIMIZED || wparam == SIZE_RESTORED) {
        NotifyBoundsChanged();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
