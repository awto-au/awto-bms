#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);

  // Fit the window to the primary monitor's WORK AREA (the screen minus the
  // taskbar): at most 1280x800 logical px, at least 40 px clear of the work
  // area's edges (so the frame + title bar never push the right/bottom edge
  // off a 1280x720 display), never below the 900x600 minimum, and centred.
  // GetMonitorInfo reports PHYSICAL pixels (the runner is PerMonitorV2
  // DPI-aware); Win32Window::Create scales logical values back up by the
  // monitor's DPI, so everything here is converted to logical first.
  constexpr int kPreferredWidth = 1280;
  constexpr int kPreferredHeight = 800;
  constexpr int kMinWidth = 900;
  constexpr int kMinHeight = 600;
  constexpr int kEdgeMargin = 40;

  const POINT primary_point = {0, 0};
  HMONITOR primary =
      ::MonitorFromPoint(primary_point, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO monitor_info = {};
  monitor_info.cbSize = sizeof(monitor_info);
  RECT work_area = {0, 0, 1280, 720};
  if (::GetMonitorInfo(primary, &monitor_info)) {
    work_area = monitor_info.rcWork;
  } else {
    ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0);
  }
  const double scale = FlutterDesktopGetDpiForMonitor(primary) / 96.0;
  const int work_left = static_cast<int>(work_area.left / scale);
  const int work_top = static_cast<int>(work_area.top / scale);
  const int work_width =
      static_cast<int>((work_area.right - work_area.left) / scale);
  const int work_height =
      static_cast<int>((work_area.bottom - work_area.top) / scale);

  const int width =
      std::max(kMinWidth, std::min(kPreferredWidth, work_width - kEdgeMargin));
  const int height = std::max(
      kMinHeight, std::min(kPreferredHeight, work_height - kEdgeMargin));
  const int left = std::max(0, work_left + (work_width - width) / 2);
  const int top = std::max(0, work_top + (work_height - height) / 2);

  Win32Window::Point origin(static_cast<unsigned int>(left),
                            static_cast<unsigned int>(top));
  Win32Window::Size size(static_cast<unsigned int>(width),
                         static_cast<unsigned int>(height));
  window.SetMinimumSize(Win32Window::Size(kMinWidth, kMinHeight));
  if (!window.Create(L"battery_reader", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
