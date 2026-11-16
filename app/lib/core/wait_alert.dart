import 'package:flutter/services.dart';

/// M3.6 等待期通知的原生桥:
///  - `start/update/stop`:一个只在"手机派出任务、正在等电脑结果"期间存在的前台服务
///    (保活会话 SSE + 通知栏常驻「正在等电脑」);
///  - `notifyResult`:这一轮结束时发一条普通通知(只在 App 不在前台时才调用)。
///
/// 没有原生通道时(测试/Web)全部静默失败,不影响主流程。
class WaitAlert {
  static const MethodChannel _channel = MethodChannel('jingling/wait');

  /// 当前是否处于等待态(幂等:重复 start 只更新文案)。
  static bool get waiting => _waiting;
  static bool _waiting = false;

  /// 启动等待。返回 false 表示没有通知权限或原生通道不可用——此时不保活,只是不打扰。
  static Future<bool> start({required String title, required String text}) async {
    if (_waiting) {
      await update(title: title, text: text);
      return true;
    }
    try {
      final started = await _channel.invokeMethod<bool>('start', {'title': title, 'text': text});
      _waiting = started == true;
      return _waiting;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> update({required String title, required String text}) async {
    if (!_waiting) return;
    try {
      await _channel.invokeMethod<void>('update', {'title': title, 'text': text});
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
  }

  static Future<void> stop() async {
    if (!_waiting) return;
    _waiting = false;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
  }

  /// 结果通知(跑完 / 出错 / 电脑断线)。App 在前台时不要调用,避免自己看着还响。
  static Future<void> notifyResult({required String title, required String text}) async {
    try {
      await _channel.invokeMethod<void>('notifyResult', {'title': title, 'text': text});
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
  }

  /// Android 13+ 的 POST_NOTIFICATIONS 运行时权限;返回当前是否已授予。
  static Future<bool> ensurePermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> canNotify() async {
    try {
      return await _channel.invokeMethod<bool>('canNotify') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 打开系统通知设置(用户拒过权限时的手动入口)。
  static Future<void> openNotificationSettings() async {
    try {
      await _channel.invokeMethod<void>('openNotificationSettings');
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
  }

  /// 仅测试用:重置内部等待态(不触碰原生)。
  static void resetForTest() {
    _waiting = false;
  }
}

/// App 是否在前台。通知只在后台时发,避免"自己正看着还响一声"。
class AppVisibility {
  static bool foreground = true;
}
