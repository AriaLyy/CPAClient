#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>
#include <unordered_map>

#include <windows.h>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void SetupTrayChannel();
  void HandleTrayMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void InitializeTray(const flutter::EncodableMap& arguments);
  void DestroyTray();
  void PopUpContextMenu();
  void SendTrayEvent(const std::string& method,
                     const flutter::EncodableMap* arguments = nullptr);
  void RebuildTrayMenu(const flutter::EncodableList& menu_items);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> tray_channel_;
  NOTIFYICONDATAW tray_icon_data_{};
  HMENU tray_menu_ = nullptr;
  HICON tray_icon_handle_ = nullptr;
  UINT tray_callback_message_ = WM_APP + 100;
  std::unordered_map<UINT, std::string> tray_command_keys_;
  UINT next_tray_command_id_ = 50000;
  bool tray_initialized_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
