import 'package:window_manager/window_manager.dart';

class NativeTrayBridge {
  Future<void> setDockVisible(bool visible) async {
    await windowManager.setSkipTaskbar(!visible);
  }
}
