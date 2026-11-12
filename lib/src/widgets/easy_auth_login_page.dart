import 'dart:async';
import 'package:flutter/material.dart';
import '../easy_auth_core.dart';
import '../easy_auth_models.dart';
import 'verification_login_form.dart';
import 'enhanced_third_party_login_buttons.dart';

/// EasyAuth 完整登录页面组件
///
/// 直接使用 EasyAuth 已缓存的租户配置，不重复初始化
class EasyAuthLoginPage extends StatefulWidget {
  /// 登录成功回调（可选，不提供则默认关闭页面并返回结果）
  final Function(LoginResult)? onLoginSuccess;

  /// 登录失败回调（可选）
  final Function(dynamic error)? onLoginFailed;

  const EasyAuthLoginPage({super.key, this.onLoginSuccess, this.onLoginFailed});

  @override
  State<EasyAuthLoginPage> createState() => _EasyAuthLoginPageState();
}

class _EasyAuthLoginPageState extends State<EasyAuthLoginPage> {
  bool _submitting = false; // 登录中的遮罩
  bool _completedPop = false; // 防止重复关闭导致返回值异常

  // 租户配置加载状态 — 跟 EasyAuth().tenantConfig 一起决定 UI 分支
  bool _loadingConfig = false;
  Object? _configError;

  @override
  void initState() {
    super.initState();
    // 如果 init() 时已经拉到缓存 / 后台已加载完,直接用现成的;
    // 否则主动拉一次(带 10 秒超时),失败就显示重试按钮 — 不再被动等 timer
    if (EasyAuth().tenantConfig == null) {
      _kickoffConfigLoad();
    }
  }

  Future<void> _kickoffConfigLoad() async {
    if (!mounted) return;
    setState(() {
      _loadingConfig = true;
      _configError = null;
    });
    try {
      await EasyAuth().reloadTenantConfig().timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('加载租户配置超时,请检查网络'),
      );
      if (!mounted) return;
      setState(() => _loadingConfig = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingConfig = false;
        _configError = e;
      });
    }
  }

  /// 处理登录成功
  void _handleLoginSuccess(LoginResult result) {
    if (!mounted) return;
    if (_completedPop) return;
    _completedPop = true;
    setState(() => _submitting = false);
    try {
      widget.onLoginSuccess?.call(result);
    } catch (_) {}
    // 默认：关闭页面并返回结果
    Navigator.of(context).pop<LoginResult>(result);
  }

  /// 处理登录失败
  void _handleLoginFailed(dynamic error) {
    if (!mounted) return;
    if (_completedPop) return;
    _completedPop = true;
    setState(() => _submitting = false);
    try {
      widget.onLoginFailed?.call(error);
    } catch (_) {}
    // 失败也立即关闭页面并把失败结果抛给外部
    Navigator.of(
      context,
    ).pop<LoginResult>(LoginResult.failure(error?.toString() ?? '登录失败'));
  }

  @override
  Widget build(BuildContext context) {
    final tenantConfig = EasyAuth().tenantConfig;
    final primaryColor = EasyAuth().primaryColor;
    final backgroundColor = EasyAuth().backgroundColor;
    final surfaceColor = EasyAuth().surfaceColor;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDarkMode ? const Color(0xFF121212) : backgroundColor,
      body: _buildBody(
        tenantConfig,
        primaryColor,
        backgroundColor,
        surfaceColor,
        isDarkMode,
      ),
    );
  }

  Widget _buildBody(
    TenantConfig? tenantConfig,
    Color primaryColor,
    Color backgroundColor,
    Color surfaceColor,
    bool isDarkMode,
  ) {
    // 配置还在加载 — 显示菊花 + 文案
    if (tenantConfig == null && _loadingConfig) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              '正在加载登录配置...',
              style: TextStyle(
                color: isDarkMode ? Colors.grey[300] : Colors.grey[600],
              ),
            ),
          ],
        ),
      );
    }

    // 配置加载失败 — 显示错误 + 重试 + 关闭 (不再死循环卡死)
    if (tenantConfig == null) {
      final err = _configError;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.cloud_off,
                size: 56,
                color: isDarkMode ? Colors.red[300] : Colors.red[600],
              ),
              const SizedBox(height: 16),
              Text(
                '登录配置加载失败',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDarkMode ? Colors.white : Colors.grey[800],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                err?.toString() ?? '请稍后再试',
                style: TextStyle(
                  fontSize: 13,
                  color: isDarkMode ? Colors.grey[400] : Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _kickoffConfigLoad,
                icon: const Icon(Icons.refresh),
                label: const Text('重新加载'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(
                  context,
                ).pop<LoginResult>(LoginResult.failure('用户取消登录')),
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
      );
    }

    // 如果配置为空或没有支持的渠道，显示错误信息
    if (tenantConfig.supportedChannels.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: isDarkMode ? Colors.red[300] : Colors.red[600],
            ),
            const SizedBox(height: 16),
            Text(
              '该租户未配置任何登录方式',
              style: TextStyle(
                fontSize: 16,
                color: isDarkMode ? Colors.grey[300] : Colors.grey[600],
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.of(
                context,
              ).pop<LoginResult>(LoginResult.failure('用户取消登录')),
              child: const Text('返回'),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        SafeArea(
          child: Column(
            children: [
              // 顶部关闭按钮
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(
                        context,
                      ).pop<LoginResult>(LoginResult.failure('用户取消登录')),
                      icon: Icon(
                        Icons.close,
                        color: isDarkMode ? Colors.white : Colors.grey[700],
                      ),
                    ),
                    const SizedBox(width: 40), // 占位，让标题居中
                  ],
                ),
              ),

              // 主要内容区域
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 20),

                      // Logo 和标题
                      _buildHeader(tenantConfig, primaryColor, isDarkMode),

                      const SizedBox(height: 24),

                      // 登录方式
                      _buildLoginMethods(
                        primaryColor,
                        surfaceColor,
                        isDarkMode,
                        tenantConfig,
                      ),

                      const SizedBox(height: 24),

                      // 隐私声明链接
                      _buildPrivacyLink(primaryColor, isDarkMode),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),

        // 登录中的遮罩
        if (_submitting)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: false,
              child: Container(
                color: Colors.black26,
                alignment: Alignment.center,
                child: const CircularProgressIndicator(),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildHeader(
    TenantConfig tenantConfig,
    Color primaryColor,
    bool isDarkMode,
  ) {
    return Column(
      children: [
        // Logo
        Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            color: primaryColor.withValues(alpha: 0.1),
            shape: BoxShape.circle,
            border: Border.all(
              color: primaryColor.withValues(alpha: 0.3),
              width: 2,
            ),
          ),
          child: tenantConfig.icon != null && tenantConfig.icon!.isNotEmpty
              ? ClipOval(
                  child: Image.network(
                    tenantConfig.icon!,
                    width: 120,
                    height: 120,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        Icon(Icons.school, size: 40, color: primaryColor),
                  ),
                )
              : Icon(Icons.school, size: 40, color: primaryColor),
        ),

        const SizedBox(height: 16),

        // 标题
        Text(
          '登录',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: isDarkMode ? Colors.white : Colors.grey[800],
          ),
        ),
      ],
    );
  }

  Widget _buildLoginMethods(
    Color primaryColor,
    Color surfaceColor,
    bool isDarkMode,
    TenantConfig tenantConfig,
  ) {
    final channels = tenantConfig.supportedChannels.where(
      (ch) => EasyAuth().isLoginChannelEnabled(ch.channelId),
    );

    // 分离验证码登录和第三方登录
    final hasSMS = channels.any((ch) => ch.channelId == 'sms');
    final hasEmail = channels.any((ch) => ch.channelId == 'email');
    final hasWechat = channels.any((ch) => ch.channelId == 'wechat');
    final hasGoogle = channels.any((ch) => ch.channelId == 'google');
    final hasApple = channels.any((ch) => ch.channelId == 'apple');

    final hasVerificationLogin = hasSMS || hasEmail;
    final hasThirdPartyLogin = hasWechat || hasGoogle || hasApple;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 验证码登录（如果支持）
        if (hasVerificationLogin) ...[
          Container(
            decoration: BoxDecoration(
              color: isDarkMode ? const Color(0xFF1E1E1E) : surfaceColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDarkMode ? Colors.grey[700]! : Colors.grey[200]!,
              ),
            ),
            child: hasSMS && hasEmail
                ? DefaultTabController(
                    length: 2,
                    child: Column(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: isDarkMode
                                ? const Color(0xFF2A2A2A)
                                : Colors.grey[100],
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(12),
                              topRight: Radius.circular(12),
                            ),
                          ),
                          child: TabBar(
                            indicatorColor: primaryColor,
                            labelColor: isDarkMode
                                ? Colors.white
                                : Colors.grey[800],
                            unselectedLabelColor: isDarkMode
                                ? Colors.grey[400]
                                : Colors.grey[500],
                            tabs: const [
                              Tab(text: '短信登录'),
                              Tab(text: '邮箱登录'),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: SizedBox(
                            height: 180,
                            child: TabBarView(
                              children: [
                                SingleChildScrollView(
                                  child: VerificationLoginForm(
                                    type: VerificationType.sms,
                                    onLoginSuccess: _handleLoginSuccess,
                                    onLoginFailed: _handleLoginFailed,
                                    onLoginStart: () =>
                                        setState(() => _submitting = true),
                                    primaryColor: primaryColor,
                                  ),
                                ),
                                SingleChildScrollView(
                                  child: VerificationLoginForm(
                                    type: VerificationType.email,
                                    reviewAccessEmail:
                                        EasyAuth().config.reviewAccessEmail,
                                    onLoginSuccess: _handleLoginSuccess,
                                    onLoginFailed: _handleLoginFailed,
                                    onLoginStart: () =>
                                        setState(() => _submitting = true),
                                    primaryColor: primaryColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.all(16),
                    child: VerificationLoginForm(
                      type: hasSMS
                          ? VerificationType.sms
                          : VerificationType.email,
                      reviewAccessEmail: EasyAuth().config.reviewAccessEmail,
                      onLoginSuccess: _handleLoginSuccess,
                      onLoginFailed: _handleLoginFailed,
                      onLoginStart: () => setState(() => _submitting = true),
                      primaryColor: primaryColor,
                    ),
                  ),
          ),
        ],

        // 分隔线
        if (hasVerificationLogin && hasThirdPartyLogin) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Divider(
                  color: isDarkMode ? Colors.grey[700] : Colors.grey[300],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '其他登录方式',
                  style: TextStyle(
                    color: isDarkMode ? Colors.grey[400] : Colors.grey[600],
                    fontSize: 12,
                  ),
                ),
              ),
              Expanded(
                child: Divider(
                  color: isDarkMode ? Colors.grey[700] : Colors.grey[300],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],

        // 第三方登录
        if (hasThirdPartyLogin)
          EnhancedThirdPartyLoginButtons(
            showWechat: hasWechat,
            showGoogle: hasGoogle,
            showApple: hasApple,
            onLoginStart: () => setState(() => _submitting = true),
            onLoginSuccess: _handleLoginSuccess,
            onLoginFailed: _handleLoginFailed,
            suppressFeedback: true,
            primaryColor: primaryColor,
          ),
      ],
    );
  }

  /// 构建隐私声明链接
  Widget _buildPrivacyLink(Color primaryColor, bool isDarkMode) {
    return Center(
      child: GestureDetector(
        onTap: () => _showPrivacyPolicy(),
        child: Text(
          '隐私政策',
          style: TextStyle(
            color: primaryColor,
            fontSize: 14,
            decoration: TextDecoration.underline,
            decorationColor: primaryColor,
          ),
        ),
      ),
    );
  }

  /// 显示隐私政策页面
  void _showPrivacyPolicy() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('隐私政策'),
        content: const SingleChildScrollView(
          child: Text(
            '我们非常重视您的隐私保护。\n\n'
            '当您使用我们的登录服务时，我们可能会收集以下信息：\n'
            '• 手机号码（用于短信验证码登录）\n'
            '• 邮箱地址（用于邮箱验证码登录）\n'
            '• 第三方账号信息（微信、QQ、苹果、谷歌等）\n'
            '• 设备信息（设备型号、操作系统等）\n\n'
            '我们收集这些信息仅用于：\n'
            '• 身份验证和账户安全\n'
            '• 提供登录认证服务\n'
            '• 防范安全风险\n'
            '• 改进服务质量\n\n'
            '我们承诺不会向第三方出售、出租或以其他方式披露您的个人信息，除非获得您的明确同意或法律法规要求。\n\n'
            '您有权查询、更正、删除您的个人信息，或撤回对个人信息处理的同意。\n\n'
            '如需查看完整的隐私政策，请访问我们的官方网站。\n\n'
            '如有任何疑问，请联系我们：privacy@kiku.com',
            style: TextStyle(fontSize: 14, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
