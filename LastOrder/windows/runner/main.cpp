#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <VersionHelpers.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// All helper processes, PyInstaller workers and browser descendants remain in
// this job. Windows closes its non-inherited handle even if the app crashes.
// Keep the handle open until process teardown: closing it also ends this runner.
bool ProtectChildProcessLifetime() {
  HANDLE job = ::CreateJobObject(nullptr, nullptr);
  if (job == nullptr) return false;
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!::SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits,
                                static_cast<DWORD>(sizeof(limits))) ||
      !::AssignProcessToJobObject(job, ::GetCurrentProcess())) {
    ::CloseHandle(job);
    return false;
  }
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (!::IsWindows10OrGreater()) {
    ::MessageBox(nullptr, L"LastOrder requires Windows 10 or later.",
                 L"LastOrder", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }
  if (!ProtectChildProcessLifetime()) {
    ::MessageBox(nullptr, L"Unable to initialize protected helper processes.",
                 L"LastOrder", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  if (FAILED(::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) {
    ::MessageBox(nullptr, L"Unable to initialize Windows application services.",
                 L"LastOrder", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 860);
  if (!window.Create(L"LastOrder", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  BOOL message_status;
  while ((message_status = ::GetMessage(&msg, nullptr, 0, 0)) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return message_status == -1 ? EXIT_FAILURE : EXIT_SUCCESS;
}
