import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'web_google_login_service.dart';
import '../easy_auth_models.dart';

/// Google登录服务类
/// 处理不同平台的Google登录逻辑（合并原生和WebView登录）
class GoogleSignInService {
  static final GoogleSignInService _instance = GoogleSignInService._internal();
  factory GoogleSignInService() => _instance;
  GoogleSignInService._internal() {
    _listenToAuthEvents();
  }

  bool _initialized = false;
  GoogleSignInAccount? _currentUser;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _authEventSubscription;

  void _listenToAuthEvents() {
    _authEventSubscription?.cancel();
    _authEventSubscription = GoogleSignIn.instance.authenticationEvents.listen((
      event,
    ) {
      switch (event) {
        case GoogleSignInAuthenticationEventSignIn(:final user):
          _currentUser = user;
          print('🔔 [GoogleSignIn] 用户登录事件: ${user.email}');
        case GoogleSignInAuthenticationEventSignOut():
          _currentUser = null;
          print('🔔 [GoogleSignIn] 用户登出事件');
      }
    });
  }

  Future<void> _ensureInitialized([TenantConfig? tenantConfig]) async {
    if (_initialized) return;

    String? clientId;
    String? serverClientId;

    if (tenantConfig != null) {
      final googleChannel = tenantConfig.supportedChannels
          .where((channel) => channel.channelId == 'google')
          .firstOrNull;

      if (googleChannel?.config != null) {
        final platform = getCurrentPlatform();
        clientId = googleChannel!.config![platform];
        serverClientId = googleChannel.config!['web'];
      }
    }

    if (clientId == null || clientId.isEmpty) {
      throw Exception(
        'Google OAuth配置缺失：未找到${getCurrentPlatform()}平台的clientId配置',
      );
    }

    print('🔑 初始化GoogleSignIn - clientId: $clientId, serverClientId: $serverClientId');
    await GoogleSignIn.instance.initialize(
      clientId: clientId,
      serverClientId: serverClientId,
    );
    _initialized = true;
  }

  /// 执行Google登录（新版本7.2.0 API）
  /// 返回形如：{ 'idToken': String?, 'email': String?, 'displayName': String? }
  Future<Map<String, dynamic>?> signIn(
    BuildContext context, [
    TenantConfig? tenantConfig,
  ]) async {
    try {
      final platform = getCurrentPlatform();
      print('🔍 Google登录 - 平台: $platform');

      // 根据平台选择登录方式
      if (platform == 'android' || platform == 'ios' || platform == 'macos') {
        // Android 和 iOS 使用原生登录
        return await _signInNative(tenantConfig);
      } else {
        // 其他平台使用WebView登录
        return await _signInWebView(context);
      }
    } catch (e) {
      print('❌ Google登录失败: $e');
      rethrow;
    }
  }

  /// 原生登录（Android/iOS）
  Future<Map<String, dynamic>?> _signInNative([
    TenantConfig? tenantConfig,
  ]) async {
    try {
      await _ensureInitialized(tenantConfig);

      // 使用新版本API进行认证
      if (!GoogleSignIn.instance.supportsAuthenticate()) {
        throw Exception('当前平台不支持Google原生认证');
      }

      print('🔍 开始Google原生登录...');
      final GoogleSignInAccount googleUser = await GoogleSignIn.instance
          .authenticate(
            scopeHint: const <String>['openid', 'profile', 'email'],
          );

      _currentUser = googleUser;

      print('✅ Google登录成功: ${googleUser.email}');
      final GoogleSignInAuthentication auth = googleUser.authentication;

      // 7.2.0 版本只返回 idToken，没有 accessToken
      return <String, dynamic>{
        'idToken': auth.idToken,
        'email': googleUser.email,
        'displayName': googleUser.displayName,
        'photoUrl': googleUser.photoUrl,
        'platform': getCurrentPlatform(),
      };
    } catch (e) {
      print('❌ Google原生登录失败: $e');
      rethrow;
    }
  }

  /// WebView登录（Web/Desktop）
  Future<Map<String, dynamic>?> _signInWebView(BuildContext context) async {
    try {
      final webService = WebGoogleLoginService();
      final result = await webService.signIn(context);

      print('🔍 WebView登录服务返回结果: $result');

      if (result == null) {
        print('❌ WebView登录被用户取消或失败');
        return null;
      }

      return result;
    } catch (e) {
      print('❌ WebView登录失败: $e');
      rethrow;
    }
  }

  /// 登出
  Future<void> signOut([TenantConfig? tenantConfig]) async {
    try {
      await _ensureInitialized(tenantConfig);
      await GoogleSignIn.instance.signOut();
      _currentUser = null;
      print('✅ Google登出成功');
    } catch (e) {
      print('❌ Google登出失败: $e');
      rethrow;
    }
  }

  /// 获取当前平台
  String getCurrentPlatform() {
    if (kIsWeb) {
      return 'web';
    } else if (Platform.isAndroid) {
      return 'android';
    } else if (Platform.isIOS) {
      return 'ios';
    } else if (Platform.isMacOS) {
      return 'macos';
    } else if (Platform.isWindows) {
      return 'windows';
    } else if (Platform.isLinux) {
      return 'linux';
    } else {
      return 'desktop';
    }
  }

  /// 检查是否已登录
  /// 通过轻量认证尝试恢复会话
  Future<bool> isSignedIn([TenantConfig? tenantConfig]) async {
    try {
      await _ensureInitialized(tenantConfig);
      final account = await GoogleSignIn.instance
          .attemptLightweightAuthentication();
      if (account != null) {
        _currentUser = account;
        return true;
      }
      return false;
    } catch (e) {
      print('❌ 检查Google登录状态失败: $e');
      return false;
    }
  }

  /// 获取当前用户
  /// 优先返回内存中的当前用户，否则尝试轻量认证恢复
  Future<GoogleSignInAccount?> getCurrentUser([
    TenantConfig? tenantConfig,
  ]) async {
    if (_currentUser != null) {
      return _currentUser;
    }

    try {
      await _ensureInitialized(tenantConfig);
      final account = await GoogleSignIn.instance
          .attemptLightweightAuthentication();
      if (account != null) {
        _currentUser = account;
      }
      return account;
    } catch (e) {
      print('❌ 获取当前Google用户失败: $e');
      return null;
    }
  }
}
