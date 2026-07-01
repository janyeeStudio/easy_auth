# EasyAuth

一个强大、易用的Flutter登录认证插件，配合`anylogin`后端服务实现多渠道统一登录。

## ✨ 特性

- 🔐 **多渠道登录**：支持短信、邮箱、微信、Google、Apple ID等多种登录方式
- 📱 **跨平台支持**：iOS和Android原生支持
- 🔄 **自动Token刷新**：内置Token自动刷新机制
- 💾 **本地会话管理**：自动保存和恢复用户会话
- 🎯 **类型安全**：完整的类型定义和错误处理
- 🚀 **简单易用**：链式API，开箱即用
- 🎨 **预置UI组件**：提供完整的登录页面和可复用组件
- 🔧 **动态配置**：从后端自动获取租户支持的登录方式

## 🚀 快速开始

### 1. 添加依赖

```yaml
dependencies:
  easy_auth:
    path: ../easy_auth  # 或发布到pub.dev后使用版本号
```

### 2. 初始化

```dart
import 'package:easy_auth/easy_auth.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 初始化EasyAuth
  await EasyAuth().init(
    EasyAuthConfig(
      baseUrl: 'https://api.janyee.com',  // anylogin服务地址（不含 /login 前缀）
      tenantId: 'kiku_app',               // 租户ID
      sceneId: 'app_native',              // 登录场景
      enableAutoRefresh: true,
    ),
  );
  
  runApp(MyApp());
}
```

### 3. 使用登录功能

#### 方式1: 使用预置UI组件（推荐，快速开始）

```dart
import 'package:easy_auth/easy_auth_ui.dart';

// 使用完整登录页（自动从后端获取支持的登录方式）
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => EasyAuthLoginPage(
      baseUrl: 'https://api.janyee.com',
      tenantId: 'kiku_app',
      sceneId: 'app_native',
      title: '登录',
      logo: Image.asset('assets/logo.png'),  // 可选
      primaryColor: Colors.pink,             // 可选
      onLoginSuccess: (result) {
        // 登录成功，跳转到主页
        Navigator.pushReplacementNamed(context, '/home');
      },
      onLoginFailed: (error) {
        // 登录失败处理
        print('登录失败: $error');
      },
    ),
  ),
);

// 或使用单独的表单组件
SMSLoginForm(
  onLoginSuccess: (result) {
    // 登录成功处理
  },
  onLoginFailed: (error) {
    // 登录失败处理
  },
  // 可选：自定义样式
  phoneDecoration: InputDecoration(/* ... */),
  sendButtonStyle: ButtonStyle(/* ... */),
  countdownSeconds: 60,
)

// 邮箱登录表单
EmailLoginForm(
  onLoginSuccess: (result) { /* ... */ },
)

// 第三方登录按钮
EnhancedThirdPartyLoginButtons(
  onLoginSuccess: (result) { /* ... */ },
  showWechat: true,
  showApple: true,
  showGoogle: true,
)
```

#### 方式2: 使用API手动实现

#### 短信验证码登录

```dart
// 发送验证码
await EasyAuth().sendSMSCode('13800138000');

// 登录
final result = await EasyAuth().loginWithSMS(
  phoneNumber: '13800138000',
  code: '123456',
);

if (result.isSuccess) {
  print('登录成功！');
  print('Token: ${result.token}');
  print('用户信息: ${result.userInfo}');
}
```

#### 邮箱验证码登录

```dart
// 发送验证码
await EasyAuth().sendEmailCode('user@example.com');

// 登录
final result = await EasyAuth().loginWithEmail(
  email: 'user@example.com',
  code: '123456',
);
```

#### 微信登录

```dart
try {
  final result = await EasyAuth().loginWithWechat();
  if (result.isSuccess) {
    print('微信登录成功！');
  }
} catch (e) {
  print('微信登录失败: $e');
}
```

#### Google登录

```dart
try {
  final result = await EasyAuth().loginWithGoogle();
  if (result.isSuccess) {
    print('Google登录成功！');
  }
} catch (e) {
  print('Google登录失败: $e');
}
```

#### Apple ID登录

```dart
try {
  // 传入 context 后,Android / Windows / Linux 等非 Apple 平台会自动走 WebView 兜底。
  final result = await EasyAuth().loginWithApple(context);
  if (result.isSuccess) {
    print('Apple登录成功！');
  }
} catch (e) {
  print('Apple登录失败: $e');
}
```

### 4. 用户信息和Token管理

```dart
// 检查登录状态
if (EasyAuth().isLoggedIn) {
  print('用户已登录');
}

// 获取当前用户
final user = EasyAuth().currentUser;
print('用户ID: ${user?.userId}');
print('昵称: ${user?.nickname}');

// 获取当前Token
final token = EasyAuth().currentToken;

// 刷新Token
final newToken = await EasyAuth().refreshToken();

// 获取用户信息（强制刷新）
final userInfo = await EasyAuth().getUserInfo(forceRefresh: true);

// 登出
await EasyAuth().logout();
```

## 📖 配置说明

### EasyAuthConfig 参数

| 参数 | 类型 | 必填 | 说明 | 示例 |
|------|------|------|------|------|
| baseUrl | String | 是 | anylogin后端服务地址（**不含** `/login` 前缀） | `https://api.janyee.com` |
| tenantId | String | 是 | 租户ID | `kiku_app` |
| sceneId | String | 是 | 登录场景ID | `app_native`, `web_login` |
| tokenExpiry | Duration | 否 | Token有效期，默认7天 | `Duration(days: 7)` |
| enableAutoRefresh | bool | 否 | 是否启用自动刷新，默认true | `true` |

**重要说明**:
- `baseUrl` **不应该**包含 `/login` 路由前缀
- API客户端会自动添加 `/login/xxx` 路径
- 例如：`baseUrl` = `https://api.janyee.com`，API路径 = `/login/getTenantConfig`
- 最终请求: `https://api.janyee.com/login/getTenantConfig` ✅

### 登录场景说明

- `app_native`: App原生登录
- `web_login`: 网页登录
- `mini_program`: 小程序登录

## 🔧 高级配置

### 微信登录配置

#### iOS配置

1. 在`Info.plist`中添加：

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleTypeRole</key>
    <string>Editor</string>
    <key>CFBundleURLName</key>
    <string>weixin</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>YOUR_WECHAT_APP_ID</string>
    </array>
  </dict>
</array>

<key>LSApplicationQueriesSchemes</key>
<array>
  <string>weixin</string>
  <string>weixinULAPI</string>
</array>
```

2. 集成微信SDK（需手动配置）

#### Android配置

1. 在`AndroidManifest.xml`中添加：

```xml
<application>
  <!-- 微信回调Activity -->
  <activity
    android:name=".wxapi.WXEntryActivity"
    android:exported="true"
    android:launchMode="singleTask" />
</application>
```

2. 集成微信SDK（需手动配置）

### Apple ID登录配置

在Xcode中启用`Sign in with Apple` Capability。

运行时分发:
- iOS / macOS 优先使用系统原生 Sign in with Apple。
- Android / Windows / Linux 会使用 WebView 登录。
- 如果 iOS / macOS entitlement 或 provisioning profile 配置不完整,SDK 会记录 `🍎 [native-apple]` 日志并回落 WebView。

WebView 兜底链路会打开 anylogin 的 `/login/apple?tenant_id=<tenantId>`。SDK 会截获
`https://auth.janyee.com/apple/callback` 回调 URL,再把完整 `callbackUrl` 提交给
`/login/directLogin`。因此 anylogin 端必须为当前租户配置正确的 `apple_web_client_id`,
`apple_team_id`, `apple_key_id`, `apple_private_key_encrypted`。

### Google登录配置

请参考 [Google Sign-In for Flutter](https://pub.dev/packages/google_sign_in) 文档配置。

## 📱 完整示例

查看 [example](example/) 目录获取完整的示例应用。

## 🔗 相关项目

- [anylogin](https://github.com/kmlixh/anylogin) - 配套的后端登录服务

## 🤝 贡献

欢迎提交Issue和Pull Request！

## 📄 许可证

MIT License

## ⚠️ 注意事项

1. **微信登录**需要在微信开放平台注册应用并获取AppID
2. **Apple ID登录**仅在iOS 13.0+可用
3. **Google登录**需要在Google Cloud Console配置OAuth 2.0客户端
4. 确保`anylogin`后端服务已正确配置和部署
5. 生产环境请使用HTTPS
6. 妥善保管tenantId和相关密钥

## 📚 详细文档

- **[UI组件文档](UI_COMPONENTS.md)** - 预置UI组件完整使用指南
- **[配置指南和注意事项](SETUP_GUIDE.md)** - 必读！包含完整的配置步骤和最佳实践
- **[动态登录更新](DYNAMIC_LOGIN_UPDATE.md)** - 动态获取租户配置的实现说明
- [完整示例](example/) - 完整的登录UI和流程演示

## 📞 支持

如有问题，请提交Issue或联系技术支持。
