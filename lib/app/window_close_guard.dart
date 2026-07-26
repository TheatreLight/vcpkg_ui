import 'package:flutter/services.dart';

abstract interface class WindowCloseGuard {
  Future<void> setPreventClose(bool preventClose);
}

final class NoopWindowCloseGuard implements WindowCloseGuard {
  const NoopWindowCloseGuard();

  @override
  Future<void> setPreventClose(bool preventClose) async {}
}

final class MethodChannelWindowCloseGuard implements WindowCloseGuard {
  const MethodChannelWindowCloseGuard();

  static const MethodChannel _channel = MethodChannel('vcpkg_ui/window');

  @override
  Future<void> setPreventClose(bool preventClose) =>
      _channel.invokeMethod<void>('setPreventClose', <String, Object>{
        'prevent': preventClose,
      });
}
