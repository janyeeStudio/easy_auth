import 'dart:async';
import 'package:fluwx/fluwx.dart';
import '../easy_auth_exception.dart';

/// 微信登录服务
///
/// 注意：fluwx 5.x 重构了授权 API（`sendWeChatAuth` / `weChatResponseEventHandler` 已废弃，
/// 替换为 `authBy(AuthType.NormalAuth(...))` + 新的事件订阅机制）。
/// 同时 easy_auth 的 PlatformException 不接受 `code:` 命名参数。
/// 这里先保留 init / isWeChatInstalled 等仍可用的部分，
/// 把 login() 暂时改为抛出"需要适配 fluwx 5.x"，避免阻塞整个 App 编译。
class WechatLoginService {
  final Fluwx _fluwx = Fluwx();
  bool _isInitialized = false;

  /// 初始化
  Future<void> init(String appId) async {
    if (_isInitialized) return;
    try {
      await _fluwx.registerApi(appId: appId, doOnIOS: true, doOnAndroid: true);
      _isInitialized = true;
    } catch (e) {
      print('⚠️ Failed to register WeChat API: $e');
    }
  }

  /// 检查微信是否安装
  Future<bool> isWeChatInstalled() async {
    return await _fluwx.isWeChatInstalled;
  }

  /// 发起微信登录
  /// 返回 auth code
  Future<String?> login() async {
    throw PlatformException(
      'WeChat login is temporarily disabled: fluwx 5.x API migration pending',
      platform: 'wechat',
    );
  }
}
