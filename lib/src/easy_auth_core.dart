import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'easy_auth_models.dart';
import 'easy_auth_api_client.dart';
import 'easy_auth_exception.dart' as auth_exception;
import 'oauth_redirect.dart';
import 'services/google_sign_in_service.dart';
import 'services/web_apple_login_service.dart';
import 'services/native_apple_login_service.dart';
import 'services/wechat_login_service.dart';
import 'apple_login_platform.dart';
import 'package:flutter/services.dart' as services;
import 'widgets/easy_auth_login_page.dart';

/// EasyAuth核心类 - 纯Flutter包
/// 提供统一的登录、登出、Token管理功能
class EasyAuth {
  EasyAuthConfig? _config;
  EasyAuthApiClient? _apiClient;
  UserInfo? _currentUser;
  String? _currentToken;
  TenantConfig? _tenantConfig; // 缓存租户配置（含可用登录方式）

  // Wechat Service
  final WechatLoginService _wechatService = WechatLoginService();

  // ==========================================================================
  // 账号合并事件总线 — 给集成 easy_auth 的业务 app 用
  //
  // 业务 app 自己也存按 user_id 索引的业务数据(订单/收藏/聊天/偏好...)。
  // 当 SDK 内部发生一次合并(resolveBindConflict 完成),
  // SDK 通过这个 broadcast Stream 把 [MergeEvent] 派发出去,业务 app
  // listen 一次,在回调里把自己的业务数据迁过去:
  //
  //   EasyAuth().onAccountMerge.listen((e) async {
  //     // 直接用 e.fromUserId / e.toUserId 屏蔽 direction 细节
  //     await myBackend.reassignOwnership(from: e.fromUserId, to: e.toUserId);
  //   });
  //
  // 用 broadcast 是因为可能有多处 subscribe(本地 db + 远程 server + UI)。
  // 在 [dispose] 里关闭(SDK 是单例,生命周期=进程,所以一般不调)。
  // ==========================================================================
  final StreamController<MergeEvent> _accountMergeController =
      StreamController<MergeEvent>.broadcast();

  /// 监听账号合并事件 — 业务 app 在 main() / 初始化时 listen 一次即可。
  /// 详见 [MergeEvent] 的文档示例。
  Stream<MergeEvent> get onAccountMerge => _accountMergeController.stream;

  static final EasyAuth _instance = EasyAuth._internal();
  factory EasyAuth() => _instance;
  EasyAuth._internal();

  /// 初始化EasyAuth
  Future<void> init(EasyAuthConfig config) async {
    _config = config;
    _apiClient = EasyAuthApiClient(
      baseUrl: config.baseUrl,
      tenantId: config.tenantId,
      sceneId: config.sceneId,
    );

    // 先快速恢复本地会话，避免首屏白屏
    await _restoreSession();

    // 优先从缓存加载租户配置（快速可用），随后后台刷新网络配置
    await _loadTenantConfigFromCache();
    // 后台刷新，不阻塞初始化
    // ignore: discarded_futures
    _refreshTenantConfigInBackground();
  }

  /// 加载租户配置 — 抛错的版本(给 UI 重试用)
  ///
  /// 成功时:写 _tenantConfig + 落 cache + 初始化微信
  /// 失败时:抛 EasyAuthException,**让上层决定怎么显示**(LoginPage 会展示重试按钮)
  Future<TenantConfig> reloadTenantConfig() async {
    final config = await apiClient.getTenantConfig();
    _tenantConfig = config;
    await _saveTenantConfigToCache(config);
    _initWechatServiceIfNeeded(config);
    return config;
  }

  /// 加载租户配置 — 兼容旧名,内部走 [reloadTenantConfig] 但吞错
  /// (init() 的后台刷新用,失败也不阻塞启动)
  Future<void> _loadTenantConfig() async {
    try {
      await reloadTenantConfig();
    } catch (e) {
      print('⚠️ 加载租户配置失败: $e');
    }
  }

  /// 从缓存加载租户配置，提升启动速度
  Future<void> _loadTenantConfigFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString('easy_auth_tenant_config');
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        _tenantConfig = TenantConfig.fromJson(json);
        // 尝试初始化微信服务（如果有缓存配置）
        _initWechatServiceIfNeeded(_tenantConfig!);
      }
    } catch (e) {
      print('⚠️ 读取租户配置缓存失败: $e');
    }
  }

  /// 保存租户配置到缓存
  Future<void> _saveTenantConfigToCache(TenantConfig config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = jsonEncode(config.toJson());
      await prefs.setString('easy_auth_tenant_config', jsonStr);
    } catch (e) {
      print('⚠️ 写入租户配置缓存失败: $e');
    }
  }

  /// 在后台刷新租户配置
  Future<void> _refreshTenantConfigInBackground() async {
    try {
      await _loadTenantConfig();
    } catch (_) {
      // 已在 _loadTenantConfig 内部处理
    }
  }

  /// 已加载的租户配置（包含 supportedChannels）。需先 init()。
  TenantConfig? get tenantConfig => _tenantConfig;

  /// 当前主题色
  Color get primaryColor => _config?.primaryColor ?? Colors.pink[300]!;

  /// 当前背景色
  Color get backgroundColor => _config?.backgroundColor ?? Colors.white;

  /// 当前表面色
  Color get surfaceColor => _config?.surfaceColor ?? Colors.grey[50]!;

  /// 当前配置
  EasyAuthConfig get config {
    if (_config == null) {
      throw auth_exception.ConfigurationException(
        'EasyAuth not initialized. Call init() first.',
      );
    }
    return _config!;
  }

  /// API客户端
  EasyAuthApiClient get apiClient {
    if (_apiClient == null) {
      throw auth_exception.ConfigurationException(
        'EasyAuth not initialized. Call init() first.',
      );
    }
    return _apiClient!;
  }

  /// 仅测试用 — 替换 ApiClient 让单测可以注入 MockClient
  /// 生产代码 (`init` 已经建好 client) 永远不该调这个。
  @visibleForTesting
  void setApiClientForTesting(EasyAuthApiClient client) {
    _apiClient = client;
  }

  /// 当前用户
  UserInfo? get currentUser => _currentUser;

  /// 当前Token
  String? get currentToken => _currentToken;

  /// 是否已登录
  bool get isLoggedIn => _currentToken != null;

  /// 初始化微信服务
  void _initWechatServiceIfNeeded(TenantConfig config) {
    try {
      SupportedChannelInfo? wechatChannel;
      for (final c in config.supportedChannels) {
        if (c.channelName == 'wechat') {
          wechatChannel = c;
          break;
        }
      }
      final appId = wechatChannel?.config?['app_id'];
      if (appId != null && appId.isNotEmpty) {
        // ignore: discarded_futures
        _wechatService.init(appId);
        print('✅ WeChat SDK initialized with AppID: $appId');
      }
    } catch (e) {
      print('⚠️ Failed to init WeChat service: $e');
    }
  }

  // ========================================
  // 短信/邮箱登录
  // ========================================

  /// 发送短信验证码
  Future<void> sendSMSCode(String phoneNumber) async {
    try {
      await apiClient.sendSMSCode(phoneNumber);
    } catch (e, stackTrace) {
      throw auth_exception.AuthenticationException(
        'Send SMS code failed: $e',
        originalError: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// 发送邮箱验证码
  Future<void> sendEmailCode(String email) async {
    try {
      await apiClient.sendEmailCode(email);
    } catch (e, stackTrace) {
      throw auth_exception.AuthenticationException(
        'Send email code failed: $e',
        originalError: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// 短信验证码登录
  Future<LoginResult> loginWithSms({
    required String phoneNumber,
    required String verificationCode,
  }) async {
    try {
      final result = await apiClient.loginWithSMS(
        phoneNumber: phoneNumber,
        code: verificationCode,
      );

      if (result.isSuccess && result.token != null) {
        await _saveSession(result.token!, result.userInfo);
      }

      return result;
    } catch (e, stackTrace) {
      throw auth_exception.AuthenticationException(
        'SMS login failed: $e',
        originalError: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// 邮箱验证码登录
  Future<LoginResult> loginWithEmail({
    required String email,
    required String verificationCode,
  }) async {
    try {
      final result = await apiClient.loginWithEmail(
        email: email,
        code: verificationCode,
      );

      if (result.isSuccess && result.token != null) {
        await _saveSession(result.token!, result.userInfo);
      }

      return result;
    } catch (e, stackTrace) {
      throw auth_exception.AuthenticationException(
        'Email login failed: $e',
        originalError: e,
        stackTrace: stackTrace,
      );
    }
  }

  // ========================================
  // 第三方登录
  // ========================================

  /// Google登录（支持多平台）
  Future<LoginResult> loginWithGoogle(BuildContext context) async {
    try {
      // 使用Google登录服务
      final googleService = GoogleSignInService();
      final result = await googleService.signIn(context, _tenantConfig);

      if (result == null) {
        throw auth_exception.PlatformException(
          'User cancelled',
          platform: 'google',
        );
      }

      // 检查WebView是否返回了callback_url
      if (result.containsKey('callbackUrl')) {
        print('✅ WebView返回回调URL，调用后端登录接口');

        // 使用callback_url调用后端登录接口
        final callbackUrl = result['callbackUrl'] as String;
        final platform = result['platform'] as String? ?? 'web';

        final loginResult = await apiClient.loginWithGoogle(
          callbackUrl: callbackUrl,
          platform: platform,
        );

        if (loginResult.isSuccess && loginResult.token != null) {
          await _saveSession(loginResult.token!, loginResult.userInfo);
        }

        return loginResult;
      } else {
        // 传统方式：使用authCode和idToken调用API
        final platform = _detectPlatform();
        print('🔍 Google登录 - 检测到平台: $platform');

        final loginResult = await apiClient.loginWithGoogle(
          authCode: result['authCode'] ?? '',
          idToken: result['idToken'],
          platform: platform, // 传递平台信息
        );

        if (loginResult.isSuccess && loginResult.token != null) {
          await _saveSession(loginResult.token!, loginResult.userInfo);
        }

        return loginResult;
      }
    } catch (e, stackTrace) {
      throw auth_exception.AuthenticationException(
        'Google login failed: $e',
        originalError: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// 检测当前平台
  String _detectPlatform() {
    if (kIsWeb) {
      return 'web';
    }

    // 使用GoogleSignInService的平台检测逻辑
    final googleService = GoogleSignInService();
    return googleService.getCurrentPlatform();
  }

  // 移除未使用的 _isWebPlatform

  // 已移除对外的统一 login() 方法，改为全屏 LoginPage

  /// Apple登录（内部API，供组件使用）
  Future<LoginResult> loginWithApple([BuildContext? context]) async {
    try {
      print('🍎 启动Apple登录...');
      return await _performAppleLogin(context);
    } catch (e, stackTrace) {
      throw auth_exception.AuthenticationException(
        'Apple login failed: $e',
        originalError: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// 跳转到登录页面（对外暴露的统一入口）
  Future<LoginResult> showLoginPage(BuildContext context) async {
    return await Navigator.of(context).push<LoginResult>(
          MaterialPageRoute(
            builder: (context) => const EasyAuthLoginPage(),
            fullscreenDialog: true,
          ),
        ) ??
        LoginResult.failure('用户取消登录');
  }

  /// Stage 5 — OAuth 2.0 Authorization Code + PKCE 登录流。
  ///
  /// 与 [loginWithSms] / [loginWithEmail] / [loginWithGoogle] 不同:
  ///   - 那几个是"嵌入式登录":直接调 anylogin /login/directLogin,得到的是
  ///     opaque token,只能给 anylogin 自己的 /login/* 用。
  ///   - 这个是"标准 OAuth 登录":在 webview 里跑 IdP 的 /oauth/authorize
  ///     流程,拿到的是 ES256 JWT access_token + refresh_token。
  ///     拿这个 token 调任何接入了 authing.AuthMiddleware 的消费方后端都能通。
  ///
  /// [clientId] / [redirectUri] 必须先在 adminFront 的 OAuth 应用管理(Stage 3)
  /// 里注册。`redirectUri` 推荐用 deep-link(如 `myapp://oauth/cb`),webview
  /// 在导航时拦截即可,不需要真跳出 app。
  ///
  /// [scope] 默认 `openid profile email user_data`。包含 `user_data` 后,
  /// 该 token 可以读写 /oauth/userdata/:key (Stage 4)。
  Future<LoginResult> loginWithRedirect({
    required BuildContext context,
    required String clientId,
    required String redirectUri,
    String scope = 'openid profile email user_data',
    String? tenantId,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final cfg = _config;
    if (cfg == null) {
      return LoginResult.failure('EasyAuth 未初始化,先调 init(EasyAuthConfig)');
    }
    final flow = OAuthRedirectFlow(
      issuerBaseUrl: cfg.baseUrl.replaceAll(RegExp(r'/$'), ''),
      clientId: clientId,
      redirectUri: redirectUri,
    );
    try {
      final result = await flow.start(
        context: context,
        scope: scope,
        tenantId: tenantId ?? cfg.tenantId,
        timeout: timeout,
      );
      // 拉一次 /oauth/userinfo 把基本身份带回来 (避免 UI 还要再调一次)
      UserInfo? userInfo;
      try {
        final resp = await http.get(
          Uri.parse(
            '${cfg.baseUrl.replaceAll(RegExp(r'/$'), '')}/oauth/userinfo',
          ),
          headers: {'Authorization': 'Bearer ${result.accessToken}'},
        );
        if (resp.statusCode == 200) {
          final m = jsonDecode(resp.body) as Map<String, dynamic>;
          // 字段名兼容:OIDC 标准是 picture,userLogin 历史叫 avatar。
          // 后端目前两个都吐(向后兼容),这里优先 picture 跟标准对齐,
          // 同时 fallback 到 avatar 兜底老服务。
          userInfo = UserInfo(
            userId: (m['sub'] as String?) ?? '',
            nickname: m['nickname'] as String?,
            avatar: (m['picture'] as String?) ?? (m['avatar'] as String?),
          );
        }
      } catch (_) {
        // userinfo failure is not fatal — token is still valid.
      }
      // 复用现有持久化路径
      await _saveSession(result.accessToken, userInfo);
      return LoginResult.success(token: result.accessToken, userInfo: userInfo);
    } on OAuthRedirectError catch (e) {
      return LoginResult.failure(e.message);
    } on TimeoutException catch (_) {
      return LoginResult.failure('OAuth 登录超时');
    } catch (e) {
      return LoginResult.failure('OAuth 登录失败: $e');
    } finally {
      flow.close();
    }
  }

  /// 智能处理登录状态（已登录显示用户信息，未登录显示登录页面）
  Future<void> handleAuthState({
    required BuildContext context,
    Function(LoginResult)? onLoginSuccess,
    Function(String)? onLoginError,
    Function(UserInfo)? onUserInfoShown,
    Function(UserInfoAction action)? onUserInfoAction,
  }) async {
    if (isLoggedIn) {
      // 已登录：显示用户信息
      print('🔐 用户已登录，显示用户信息');
      _showUserInfoDialog(context, onUserInfoShown, onUserInfoAction);
    } else {
      // 未登录：显示登录页面
      print('🔐 用户未登录，启动登录');
      try {
        final result = await showLoginPage(context);
        if (result.isSuccess) {
          if (onLoginSuccess != null) {
            onLoginSuccess(result);
          }
        } else {
          if (onLoginError != null) {
            onLoginError(result.message ?? '登录失败');
          }
        }
      } catch (e) {
        if (onLoginError != null) {
          onLoginError(e.toString());
        }
      }
    }
  }

  /// 显示用户信息编辑页面
  void showEditUserInfo(
    BuildContext context, {
    Function(UserInfoAction action)? onUserInfoAction,
  }) {
    if (!isLoggedIn) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先登录')));
      return;
    }

    final user = currentUser;
    if (user == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('用户信息获取失败')));
      return;
    }

    _showEditUserInfoDialog(context, user, onUserInfoAction);
  }

  /// 显示用户信息对话框
  void _showUserInfoDialog(
    BuildContext context,
    Function(UserInfo)? onUserInfoShown,
    Function(UserInfoAction action)? onUserInfoAction,
  ) {
    final user = currentUser;
    if (user == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('用户信息'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('昵称: ${user.nickname ?? user.username ?? 'Kiku用户'}'),
            const SizedBox(height: 8),
            Text('邮箱: ${user.email ?? '未设置'}'),
            const SizedBox(height: 8),
            Text('手机: ${user.phone ?? '未设置'}'),
            const SizedBox(height: 8),
            Text('用户ID: ${user.userId}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              // 显示编辑用户信息页面
              _showEditUserInfoDialog(context, user, onUserInfoAction);
            },
            child: const Text('编辑'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              // 退出登录
              logout()
                  .then((_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('已退出登录')));
                    }
                    if (onUserInfoAction != null) {
                      onUserInfoAction(UserInfoAction.loggedOut);
                    }
                  })
                  .catchError((error) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text('退出登录失败: $error')));
                    }
                  });
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );

    if (onUserInfoShown != null) {
      onUserInfoShown(user);
    }
  }

  /// 显示编辑用户信息对话框
  void _showEditUserInfoDialog(
    BuildContext context,
    UserInfo user,
    Function(UserInfoAction action)? onUserInfoAction,
  ) {
    final nicknameController = TextEditingController(text: user.nickname ?? '');
    final avatarController = TextEditingController(text: user.avatar ?? '');
    bool isLoading = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('编辑用户信息'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 昵称输入框
                TextField(
                  controller: nicknameController,
                  decoration: const InputDecoration(
                    labelText: '昵称',
                    hintText: '请输入昵称',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),

                // 头像URL输入框
                TextField(
                  controller: avatarController,
                  decoration: const InputDecoration(
                    labelText: '头像URL',
                    hintText: '请输入头像链接',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),

                // 当前头像预览
                if (user.avatar != null && user.avatar!.isNotEmpty)
                  Column(
                    children: [
                      const Text(
                        '当前头像:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      CircleAvatar(
                        radius: 40,
                        backgroundImage: NetworkImage(user.avatar!),
                        onBackgroundImageError: (exception, stackTrace) {
                          // 头像加载失败时显示默认图标
                        },
                        child: user.avatar == null || user.avatar!.isEmpty
                            ? const Icon(Icons.person, size: 40)
                            : null,
                      ),
                    ],
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: isLoading ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: isLoading
                  ? null
                  : () async {
                      setState(() {
                        isLoading = true;
                      });

                      try {
                        // 调用更新用户信息API
                        await updateUserInfo(
                          nickname: nicknameController.text.trim().isEmpty
                              ? null
                              : nicknameController.text.trim(),
                          avatar: avatarController.text.trim().isEmpty
                              ? null
                              : avatarController.text.trim(),
                        );

                        if (context.mounted) {
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('用户信息更新成功')),
                          );
                          if (onUserInfoAction != null) {
                            onUserInfoAction(UserInfoAction.edited);
                          }
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(SnackBar(content: Text('更新失败: $e')));
                        }
                      } finally {
                        if (context.mounted) {
                          setState(() {
                            isLoading = false;
                          });
                        }
                      }
                    },
              child: isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  /// 执行Apple登录（统一内部方法）
  Future<LoginResult> _performAppleLogin([BuildContext? context]) async {
    // 平台规则：
    // - iOS => 原生登录（内置原生服务）
    // - macOS Developer ID / Web / Android / Windows / Linux => WebView 登录
    final useNative = _shouldUseAppleNative();

    if (useNative) {
      try {
        return await _loginWithAppleNative();
      } on services.MissingPluginException catch (e) {
        // 原生插件未注册 — 极少见(sign_in_with_apple 没装好)
        print('🍎 [native-apple] MissingPluginException: $e');
        if (context != null) return await _loginWithAppleWeb(context);
        rethrow;
      } on services.PlatformException catch (e) {
        // 这是最常见的 native 失败路径(iOS 缺 Capability)
        //   code='1000' / domain='AKAuthenticationError' = 用户取消,不该兜底
        //   code='1001' / authorizedOperation 失败 = 系统拒绝
        //   code='AuthenticationServices' + canceled-by-user = 用户取消
        //   其他都很可能是配置缺失,打详细 log 帮业务方诊断
        print(
          '🍎 [native-apple] PlatformException: code=${e.code} '
          'message=${e.message} details=${e.details}',
        );
        final cancelled =
            (e.code == '1000' ||
            (e.message ?? '').toLowerCase().contains('cancel'));
        if (cancelled) {
          // 用户主动取消 → 不要回落 web
          throw auth_exception.PlatformException(
            'User cancelled',
            platform: 'apple',
          );
        }
        // 配置缺失 / 系统拒绝 → 回落 web,但打条提醒
        print(
          '🍎 [native-apple] 可能是 iOS 缺 Sign in with Apple '
          'entitlement;回落到 WebView 登录。详细配置见 SETUP_GUIDE。',
        );
        if (context != null) return await _loginWithAppleWeb(context);
        rethrow;
      } catch (e, st) {
        print('🍎 [native-apple] 未知错误: $e\n$st');
        if (context != null) return await _loginWithAppleWeb(context);
        rethrow;
      }
    }

    if (context == null) {
      throw auth_exception.PlatformException(
        'WebView login requires BuildContext',
        platform: 'web',
      );
    }
    return await _loginWithAppleWeb(context);
  }

  /// 是否应使用 Apple 原生登录。Developer ID macOS 不支持该 capability。
  bool _shouldUseAppleNative() {
    return shouldUseNativeAppleLogin(defaultTargetPlatform);
  }

  /// Apple原生登录（私有方法）
  Future<LoginResult> _loginWithAppleNative() async {
    // 使用内置原生服务
    final result = await NativeAppleLoginService().signIn();

    if (result == null) {
      throw auth_exception.PlatformException(
        'User cancelled',
        platform: 'apple',
      );
    }

    final loginResult = await apiClient.loginWithApple(
      idToken: result['idToken'],
      authCode: result['authCode'],
    );

    if (loginResult.isSuccess && loginResult.token != null) {
      await _saveSession(loginResult.token!, loginResult.userInfo);
    }

    return loginResult;
  }

  /// Apple Web登录（私有方法）
  Future<LoginResult> _loginWithAppleWeb(BuildContext context) async {
    final webAppleService = WebAppleLoginService();
    final result = await webAppleService.signIn(context);

    if (result == null) {
      throw auth_exception.PlatformException(
        'User cancelled',
        platform: 'apple',
      );
    }

    // 检查是否是WebView回调结果
    if (result.containsKey('callbackUrl')) {
      final callbackUrl = result['callbackUrl'] as String;
      final platform = result['platform'] as String? ?? 'web';

      final loginResult = await apiClient.loginWithAppleWeb(
        callbackUrl: callbackUrl,
        platform: platform,
      );

      if (loginResult.isSuccess && loginResult.token != null) {
        await _saveSession(loginResult.token!, loginResult.userInfo);
      }

      return loginResult;
    } else {
      // 传统方式：使用authCode和idToken调用API
      final loginResult = await apiClient.loginWithApple(
        authCode: result['authCode'] ?? '',
        idToken: result['idToken'],
      );

      if (loginResult.isSuccess && loginResult.token != null) {
        await _saveSession(loginResult.token!, loginResult.userInfo);
      }

      return loginResult;
    }
  }

  /// 微信登录
  Future<LoginResult> loginWithWechat() async {
    try {
      // 1. 获取Auth Code
      final authCode = await _wechatService.login();

      if (authCode == null) {
        throw auth_exception.PlatformException(
          'User cancelled',
          platform: 'wechat',
        );
      }

      // 2. 调用后端登录
      final loginResult = await apiClient.loginWithWechat(authCode);

      if (loginResult.isSuccess && loginResult.token != null) {
        await _saveSession(loginResult.token!, loginResult.userInfo);
      }

      return loginResult;
    } catch (e, stackTrace) {
      throw auth_exception.AuthenticationException(
        'Wechat login failed: $e',
        originalError: e,
        stackTrace: stackTrace,
      );
    }
  }

  // ========================================
  // 回调设置
  // ========================================

  // ========================================
  // 会话管理
  // ========================================

  /// 登出
  Future<void> logout() async {
    try {
      if (_currentToken != null) {
        await apiClient.logout(_currentToken!);
      }

      // 同时登出第三方服务
      try {
        final googleService = GoogleSignInService();
        await googleService.signOut(_tenantConfig);
      } catch (e) {
        print('Warning: Google signOut failed: $e');
      }
    } catch (e) {
      print('Warning: Logout API failed: $e');
    } finally {
      await _clearSession();
    }
  }

  /// 刷新Token
  Future<void> refreshToken() async {
    if (_currentToken == null) return;

    try {
      final newToken = await apiClient.refreshToken(_currentToken!);
      _currentToken = newToken;
      await _saveToken(newToken);
    } catch (e) {
      print('Token refresh failed: $e');
      await _clearSession();
    }
  }

  /// 更新用户信息
  Future<UserInfo> updateUserInfo({String? nickname, String? avatar}) async {
    if (_currentToken == null) {
      throw auth_exception.AuthenticationException('User not logged in');
    }

    try {
      final updatedUser = await apiClient.updateUserInfo(
        token: _currentToken!,
        nickname: nickname,
        avatar: avatar,
      );

      // 更新本地用户信息
      _currentUser = updatedUser;
      await _saveUserInfo(updatedUser);

      return updatedUser;
    } catch (e, stackTrace) {
      throw auth_exception.AuthenticationException(
        'Failed to update user info: $e',
        originalError: e,
        stackTrace: stackTrace,
      );
    }
  }

  // ========================================
  // 私有方法
  // ========================================

  Future<void> _saveSession(String token, UserInfo? userInfo) async {
    _currentToken = token;
    _currentUser = userInfo;
    await _saveToken(token);
    if (userInfo != null) {
      await _saveUserInfo(userInfo);
    }
  }

  Future<void> _clearSession() async {
    _currentToken = null;
    _currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('easy_auth_token');
    await prefs.remove('easy_auth_user_info');
  }

  Future<void> _restoreSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('easy_auth_token');
      final userInfoStr = prefs.getString('easy_auth_user_info');

      if (token != null) {
        _currentToken = token;
        if (userInfoStr != null) {
          final userInfoJson = jsonDecode(userInfoStr) as Map<String, dynamic>;
          _currentUser = UserInfo.fromJson(userInfoJson);
        }
      }
    } catch (e) {
      print('Failed to restore session: $e');
    }
  }

  Future<void> _saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('easy_auth_token', token);
  }

  Future<void> _saveUserInfo(UserInfo userInfo) async {
    final prefs = await SharedPreferences.getInstance();
    final userInfoStr = jsonEncode(userInfo.toJson());
    await prefs.setString('easy_auth_user_info', userInfoStr);
  }

  // ==========================================================================
  // 跨渠道账号绑定 / 合并 (对应 userLogin/binding.go)
  // ==========================================================================

  /// 底层 API:给定 channel_id + channel_data,在当前已登录态下做绑定。
  ///
  /// channel_data 的字段约定跟 loginWith* 系列一致 — 例如:
  ///   sms     → {phone, code}
  ///   email   → {email, code}
  ///   wechat  → {code}
  ///   apple   → {id_token, code}
  ///   google  → {id_token, code, platform} 等
  ///
  /// 返回 [BindResult] sealed family。冲突场景下需要再调 [resolveBindConflict]
  /// 完成合并。
  ///
  /// 错误处理:
  ///   - 未登录 → 抛 [auth_exception.EasyAuthException]
  ///   - 当前 token 对应的账号被合并 → 抛 [AccountStateException]
  Future<BindResult> bindChannel({
    required String channelId,
    required Map<String, dynamic> channelData,
  }) async {
    if (!isLoggedIn) {
      throw auth_exception.EasyAuthException('not logged in — bind 需要已登录态');
    }
    return apiClient.bindChannel(
      token: _currentToken!,
      channelId: channelId,
      channelData: channelData,
    );
  }

  /// SMS 绑定:用户在 UI 输入 phone + code 调进来
  Future<BindResult> bindChannelSms({
    required String phoneNumber,
    required String code,
  }) => bindChannel(
    channelId: 'sms',
    channelData: {'phone': phoneNumber, 'code': code},
  );

  /// 邮箱绑定
  Future<BindResult> bindChannelEmail({
    required String email,
    required String code,
  }) => bindChannel(
    channelId: 'email',
    channelData: {'email': email, 'code': code},
  );

  /// 微信绑定:用户先走微信 SDK 拿 authCode 再调进来
  Future<BindResult> bindChannelWechat({required String authCode}) =>
      bindChannel(channelId: 'wechat', channelData: {'code': authCode});

  /// Apple 绑定:iOS 走原生 SDK；macOS Developer ID 与其它平台走 WebView。
  Future<BindResult> bindChannelApple([BuildContext? context]) async {
    if (_shouldUseAppleNative()) {
      final result = await NativeAppleLoginService().signIn();
      if (result == null) {
        throw auth_exception.PlatformException(
          'User cancelled',
          platform: 'apple',
        );
      }
      return bindChannel(
        channelId: 'apple',
        channelData: {
          if (result['idToken'] != null) 'id_token': result['idToken'],
          if (result['authCode'] != null) 'code': result['authCode'],
        },
      );
    }
    if (context == null) {
      throw auth_exception.PlatformException(
        'WebView bind requires BuildContext',
        platform: 'web',
      );
    }
    final webResult = await WebAppleLoginService().signIn(context);
    if (webResult == null) {
      throw auth_exception.PlatformException(
        'User cancelled',
        platform: 'apple',
      );
    }
    return bindChannel(
      channelId: 'apple',
      channelData: {
        if (webResult['idToken'] != null) 'id_token': webResult['idToken'],
        if (webResult['authCode'] != null) 'code': webResult['authCode'],
        'platform': 'web',
      },
    );
  }

  /// Google 绑定:复用 GoogleSignInService 拿 idToken,再调通用 bindChannel
  Future<BindResult> bindChannelGoogle(BuildContext context) async {
    final result = await GoogleSignInService().signIn(context, _tenantConfig);
    if (result == null) {
      throw auth_exception.PlatformException(
        'User cancelled',
        platform: 'google',
      );
    }
    return bindChannel(
      channelId: 'google',
      channelData: {
        if (result['idToken'] != null) 'id_token': result['idToken'],
        if (result['authCode'] != null) 'code': result['authCode'],
        if (result['platform'] != null) 'platform': result['platform'],
      },
    );
  }

  // ------------------------------------------------------------------
  // 冲突解决 / 回滚 / 解绑 / 查列表
  // ------------------------------------------------------------------

  /// 完成冲突合并 — 把 [conflictToken] 和 [action] 传回后端
  ///
  /// 注意:如果 action=[ResolveAction.meIntoOther],完成后当前 token 失效,
  /// 客户端应该:
  ///   1. 提示用户"已合并到 xxx 账号,请重新登录"
  ///   2. 调用 [logout] 清本地 session
  ///   3. 引导走对方账号的登录流程
  Future<BindResult> resolveBindConflict({
    required String conflictToken,
    required ResolveAction action,
  }) async {
    if (!isLoggedIn) {
      throw auth_exception.EasyAuthException('not logged in');
    }
    final result = await apiClient.resolveBindConflict(
      token: _currentToken!,
      conflictToken: conflictToken,
      action: action,
    );
    // 成功后刷新 currentUser 的 linkedChannels(轻量,失败也不抛)
    if (result is BindOk) {
      // 派发 merge 事件给消费方 app(在它处理完业务数据迁移前不要继续动 UI)
      if (result.mergeEvent != null) {
        _accountMergeController.add(result.mergeEvent!);
      }
      try {
        await refreshLinkedChannels();
      } catch (_) {}
    }
    return result;
  }

  // (旧 revertMerge 已删 — 账号合并不可逆)

  /// 上传 200x200 PNG 头像。客户端要先 image_picker 选图 → image_cropper
  /// crop/resize 到 200x200 → encode 成 PNG 再传 [pngBytes]。
  ///
  /// 成功返回头像 URL(已带 etag query),业务 app 把它存到 user.avatar 字段。
  Future<({String etag, String url})> updateAvatar(List<int> pngBytes) async {
    if (!isLoggedIn) {
      throw auth_exception.EasyAuthException('not logged in');
    }
    return apiClient.updateAvatar(token: _currentToken!, pngBytes: pngBytes);
  }

  /// 拼当前用户的头像 URL(GET /user/avatar/:userId),带 etag cache buster。
  /// 业务 app 用 `Image.network(EasyAuth().myAvatarUrl()!)` 显示即可。
  String? myAvatarUrl({String? etag}) {
    final uid = _currentUser?.userId;
    if (uid == null || uid.isEmpty) return null;
    return apiClient.avatarUrl(uid, cacheBuster: etag);
  }

  /// 解绑某个渠道。后端会拦截"最后一个登录方式"(返 500 + 提示)。
  Future<void> unbindChannel(String channelId) async {
    if (!isLoggedIn) {
      throw auth_exception.EasyAuthException('not logged in');
    }
    await apiClient.unbindChannel(token: _currentToken!, channelId: channelId);
  }

  /// 查当前已登录用户的绑定渠道列表(channel_user_id 脱敏)
  Future<List<LinkedChannel>> myChannels() async {
    if (!isLoggedIn) {
      throw auth_exception.EasyAuthException('not logged in');
    }
    return apiClient.myChannels(_currentToken!);
  }

  /// 刷新内存 / SharedPreferences 里的 [LinkedChannel] 列表
  /// (绑定 / 解绑 / 合并完成后建议调一次,UI 反映最新状态)
  ///
  /// 当前 SDK 的 UserInfo 没有把 linkedChannels 内嵌(避免 OIDC userinfo
  /// 响应膨胀)。要展示绑定列表请直接调 [myChannels]。
  Future<void> refreshLinkedChannels() async {
    // 占位:目前的设计是 myChannels() 即取即用。如果未来要把
    // linkedChannels 内嵌到 UserInfo,这里就是写入点。
  }
}
