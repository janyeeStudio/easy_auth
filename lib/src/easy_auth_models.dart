import 'package:flutter/material.dart';

/// 配置类
class EasyAuthConfig {
  final String baseUrl;
  final String tenantId;
  final String sceneId;
  final bool enableAutoRefresh;
  final Duration? autoRefreshInterval;
  final Color? primaryColor;
  final Color? backgroundColor;
  final Color? surfaceColor;

  const EasyAuthConfig({
    required this.baseUrl,
    required this.tenantId,
    required this.sceneId,
    this.enableAutoRefresh = true,
    this.autoRefreshInterval,
    this.primaryColor,
    this.backgroundColor,
    this.surfaceColor,
  });
}

/// Snapshot emitted whenever the persisted login session changes.
class AuthSession {
  final String token;
  final UserInfo? userInfo;

  const AuthSession({required this.token, this.userInfo});
}

/// 用户信息
class UserInfo {
  final String userId;
  final String? username;
  final String? nickname;
  final String? email;
  final String? phone;
  final String? avatar;
  final Map<String, dynamic>? extra;

  UserInfo({
    required this.userId,
    this.username,
    this.nickname,
    this.email,
    this.phone,
    this.avatar,
    this.extra,
  });

  factory UserInfo.fromJson(Map<String, dynamic> json) {
    return UserInfo(
      // OIDC userinfo 用 sub,/login/getUserInfo 用 user_id,兼容两种
      userId: (json['user_id'] as String?) ?? (json['sub'] as String?) ?? '',
      username: json['username'] as String?,
      nickname: json['nickname'] as String?,
      // OIDC phone scope 给 phone_number;老接口给 phone
      email: json['email'] as String?,
      phone: (json['phone'] as String?) ?? (json['phone_number'] as String?),
      // OIDC 标准是 picture,userLogin 历史叫 avatar,优先标准再 fallback
      avatar: (json['picture'] as String?) ?? (json['avatar'] as String?),
      extra: json['extra'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'user_id': userId,
      if (username != null) 'username': username,
      if (nickname != null) 'nickname': nickname,
      if (email != null) 'email': email,
      if (phone != null) 'phone': phone,
      if (avatar != null) 'avatar': avatar,
      if (extra != null) 'extra': extra,
    };
  }
}

/// 登录结果
class LoginResult {
  final LoginStatus status;
  final String? token;
  final UserInfo? userInfo;
  final String? message;

  bool get isSuccess => status == LoginStatus.success;

  LoginResult({required this.status, this.token, this.userInfo, this.message});

  /// 创建失败结果
  factory LoginResult.failure(String message) {
    return LoginResult(status: LoginStatus.failed, message: message);
  }

  /// 创建成功结果
  factory LoginResult.success({
    required String token,
    UserInfo? userInfo,
    String? message,
  }) {
    return LoginResult(
      status: LoginStatus.success,
      token: token,
      userInfo: userInfo,
      message: message,
    );
  }

  factory LoginResult.fromJson(Map<String, dynamic> json) {
    final statusStr = json['status'] as String?;
    final status = LoginStatus.values.firstWhere(
      (e) => e.name == statusStr,
      orElse: () => LoginStatus.pending,
    );

    return LoginResult(
      status: status,
      token: json['token'] as String?,
      userInfo: json['user_info'] != null
          ? UserInfo.fromJson(json['user_info'] as Map<String, dynamic>)
          : null,
      message: json['message'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'status': status.name,
      if (token != null) 'token': token,
      if (userInfo != null) 'user_info': userInfo!.toJson(),
      if (message != null) 'message': message,
    };
  }
}

/// 登录状态
enum LoginStatus {
  /// 等待中（轮询中）
  pending,

  /// 成功（已完成，且登录成功）
  success,

  /// 失败（已完成，但登录失败）
  failed,

  /// 超时
  timeout,

  /// 取消
  cancelled,
}

/// 登录渠道
enum LoginChannel {
  wechat,
  apple,
  google,
  sms,
  email;

  String get id {
    switch (this) {
      case LoginChannel.wechat:
        return 'wechat';
      case LoginChannel.apple:
        return 'apple';
      case LoginChannel.google:
        return 'google';
      case LoginChannel.sms:
        return 'sms';
      case LoginChannel.email:
        return 'email';
    }
  }

  String get displayName {
    switch (this) {
      case LoginChannel.wechat:
        return '微信登录';
      case LoginChannel.apple:
        return 'Apple ID登录';
      case LoginChannel.google:
        return 'Google登录';
      case LoginChannel.sms:
        return '短信验证码登录';
      case LoginChannel.email:
        return '邮箱验证码登录';
    }
  }
}

/// 支持的登录渠道信息
class SupportedChannelInfo {
  final String channelId;
  final String channelName;
  final String channelTitle;
  final int sortOrder;
  final Map<String, String>? config;

  SupportedChannelInfo({
    required this.channelId,
    required this.channelName,
    required this.channelTitle,
    required this.sortOrder,
    this.config,
  });

  factory SupportedChannelInfo.fromJson(Map<String, dynamic> json) {
    // 处理config字段
    Map<String, String>? config;
    if (json['config'] != null) {
      config = Map<String, String>.from(json['config'] as Map);
    }

    return SupportedChannelInfo(
      channelId: json['channel_id'] as String? ?? '',
      channelName: json['channel_name'] as String? ?? '',
      channelTitle: json['channel_title'] as String? ?? '',
      sortOrder: json['sort_order'] as int? ?? 0,
      config: config,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'channel_id': channelId,
      'channel_name': channelName,
      'channel_title': channelTitle,
      'sort_order': sortOrder,
      if (config != null) 'config': config,
    };
  }
}

/// 租户配置信息
class TenantConfig {
  final String tenantId;
  final String tenantName;
  final String? icon;
  final List<SupportedChannelInfo> supportedChannels;
  final String? defaultChannel;

  TenantConfig({
    required this.tenantId,
    required this.tenantName,
    this.icon,
    required this.supportedChannels,
    this.defaultChannel,
  });

  factory TenantConfig.fromJson(Map<String, dynamic> json) {
    final channelsJson = json['supported_channels'] as List<dynamic>? ?? [];
    final channels = channelsJson
        .map((ch) => SupportedChannelInfo.fromJson(ch as Map<String, dynamic>))
        .toList();

    return TenantConfig(
      tenantId: json['tenant_id'] as String? ?? '',
      tenantName: json['tenant_name'] as String? ?? '',
      icon: json['icon'] as String?,
      supportedChannels: channels,
      defaultChannel: json['default_channel'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'tenant_id': tenantId,
      'tenant_name': tenantName,
      if (icon != null) 'icon': icon,
      'supported_channels': supportedChannels.map((e) => e.toJson()).toList(),
      if (defaultChannel != null) 'default_channel': defaultChannel,
    };
  }
}

/// 用户信息页面内的动作
enum UserInfoAction { none, edited, loggedOut }

// ============================================================================
// 跨渠道账号绑定 / 合并 (对应后端 binding.go)
// ============================================================================

/// 当前 user 绑定的某条渠道(channel_user_id 后端已脱敏)
class LinkedChannel {
  final String channelId;
  final String channelName;
  final String channelUserIdMasked;
  final String? nickname;
  final String? sceneId;
  final DateTime boundAt;

  LinkedChannel({
    required this.channelId,
    required this.channelName,
    required this.channelUserIdMasked,
    this.nickname,
    this.sceneId,
    required this.boundAt,
  });

  factory LinkedChannel.fromJson(Map<String, dynamic> json) {
    return LinkedChannel(
      channelId: json['channel_id'] as String? ?? '',
      channelName: json['channel_name'] as String? ?? '',
      channelUserIdMasked: json['channel_user_id_masked'] as String? ?? '',
      nickname: json['nickname'] as String?,
      sceneId: json['scene_id'] as String?,
      boundAt: DateTime.tryParse(json['bound_at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// 冲突对话框里展示的另一边账号摘要(不带原始 user_id,只有 masked)
class AccountSummary {
  final String userIdMasked;
  final String? nickname;
  final String? avatar;
  final List<String> boundChannels;
  final DateTime createdAt;

  AccountSummary({
    required this.userIdMasked,
    this.nickname,
    this.avatar,
    required this.boundChannels,
    required this.createdAt,
  });

  factory AccountSummary.fromJson(Map<String, dynamic> json) {
    final ch = (json['bound_channels'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
    return AccountSummary(
      userIdMasked: json['user_id_masked'] as String? ?? '',
      nickname: json['nickname'] as String?,
      avatar: json['avatar'] as String?,
      boundChannels: ch,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// 绑定结果 — sealed class,三种形态
///
/// SDK 调用方一般这样处理:
/// ```
/// switch (await EasyAuth().bindChannelGoogle(ctx)) {
///   case BindOk(:final linkedChannels): // 成功,更新 UI
///   case BindAlreadyBound(:final linkedChannels): // 幂等
///   case BindConflict(:final conflictToken, :final other, :final current):
///     final action = await showBindConflictDialog(ctx, other, current);
///     await EasyAuth().resolveBindConflict(conflictToken, action);
///   case BindError(:final message): // 网络/服务器错误
/// }
/// ```
sealed class BindResult {
  const BindResult();

  factory BindResult.fromJson(Map<String, dynamic> json, {int httpStatus = 200}) {
    final status = json['status'] as String? ?? '';
    final linked = ((json['linked_channels'] as List?) ?? [])
        .map((e) => LinkedChannel.fromJson(e as Map<String, dynamic>))
        .toList();
    // merge_event 只在 resolveBindConflict 真正完成 merge 时出现
    final mergeEvent = json['merge_event'] != null
        ? MergeEvent.fromJson(json['merge_event'] as Map<String, dynamic>)
        : null;
    if (status == 'ok') return BindOk(linkedChannels: linked, mergeEvent: mergeEvent);
    if (status == 'already_bound') return BindAlreadyBound(linkedChannels: linked);
    if (status == 'conflict') {
      final ct = json['conflict_token'] as String? ?? '';
      final other = AccountSummary.fromJson(json['other_user_summary'] as Map<String, dynamic>? ?? {});
      final me = json['current_user_summary'] != null
          ? AccountSummary.fromJson(json['current_user_summary'] as Map<String, dynamic>)
          : null;
      return BindConflict(conflictToken: ct, other: other, current: me);
    }
    return BindError(message: 'unknown bind status: $status (http $httpStatus)');
  }
}

class BindOk extends BindResult {
  final List<LinkedChannel> linkedChannels;
  /// 仅当本次是 resolveBindConflict 完成的合并时非 null。
  /// SDK 会自动 emit 到 [EasyAuth.onAccountMerge],一般业务 app
  /// 不需要直接读这个字段。
  final MergeEvent? mergeEvent;
  const BindOk({required this.linkedChannels, this.mergeEvent});
}

class BindAlreadyBound extends BindResult {
  final List<LinkedChannel> linkedChannels;
  const BindAlreadyBound({required this.linkedChannels});
}

class BindConflict extends BindResult {
  /// 15 分钟内可调 resolveBindConflict 解决,过期需要重新发起 bind
  final String conflictToken;
  final AccountSummary other;
  final AccountSummary? current;
  const BindConflict({
    required this.conflictToken,
    required this.other,
    this.current,
  });
}

class BindError extends BindResult {
  final String message;
  const BindError({required this.message});
}

/// 冲突合并方向
enum ResolveAction {
  /// 把对方账号吞掉,当前账号留下
  otherIntoMe('other_into_me'),

  /// 把当前账号吞掉,对方留下(完成后当前 token 失效,需切到对方账号重登)
  meIntoOther('me_into_other'),

  /// 啥都不做(放弃绑定)
  abort('abort');

  final String wire;
  const ResolveAction(this.wire);
}

/// 账号合并事件 — 通过 [EasyAuth.onAccountMerge] Stream 分发给消费方 app。
///
/// **关键用途**:集成 easy_auth 的业务 app 自己也存了一堆按 user_id 索引的
/// 业务数据(订单、收藏、聊天、用户偏好...)。当 SDK 触发了一次账号合并,
/// 业务 app 必须把它自己的数据从 [sourceUserId] 迁到 [targetUserId],
/// 否则数据会"孤悬"在不再使用的 user_id 下。
///
/// **合并不可逆** — 一旦触发就是终态,没有 revert / 软迁移窗口。业务 app
/// 应该直接做硬迁移(`UPDATE ... SET user_id = target WHERE user_id = source`)。
///
/// 监听方式(应用启动时一次):
/// ```
/// EasyAuth().onAccountMerge.listen((event) async {
///   await myBackend.reassignOwnership(
///     fromUserId: event.fromUserId,
///     toUserId:   event.toUserId,
///     mergeId:    event.mergeId,  // 业务后端用它做幂等
///   );
/// });
/// ```
class MergeEvent {
  final String mergeId;
  final MergeDirection direction;
  final String sourceUserId;
  final String targetUserId;
  final DateTime mergedAt;

  MergeEvent({
    required this.mergeId,
    required this.direction,
    required this.sourceUserId,
    required this.targetUserId,
    required this.mergedAt,
  });

  factory MergeEvent.fromJson(Map<String, dynamic> json) {
    final dirStr = json['direction'] as String? ?? '';
    return MergeEvent(
      mergeId: json['merge_id'] as String? ?? '',
      direction: MergeDirection.values.firstWhere(
        (d) => d.wire == dirStr,
        orElse: () => MergeDirection.otherIntoMe,
      ),
      sourceUserId: json['source_user_id'] as String? ?? '',
      targetUserId: json['target_user_id'] as String? ?? '',
      mergedAt: DateTime.tryParse(json['merged_at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  /// 业务 app 真正要迁移的方向: from → to
  /// (保留这两个 getter 为了 API 稳定 — 跟 sourceUserId/targetUserId 等价)
  String get fromUserId => sourceUserId;
  String get toUserId => targetUserId;

  @override
  String toString() => 'MergeEvent($mergeId, $direction, $sourceUserId → $targetUserId)';
}

/// 合并方向 — 仅记录"谁吞谁",不影响数据迁移方向(永远是 source → target)
enum MergeDirection {
  /// 对方账号被吞,当前账号留下
  otherIntoMe('other_into_me'),

  /// 当前账号被吞,对方留下 — SDK 已 logout,客户端会引导用户用对方账号重新登录
  meIntoOther('me_into_other');

  final String wire;
  const MergeDirection(this.wire);
}

/// token 验证时账号已被合并/注销的异常 — SDK 收到 401 + error_code 时抛
class AccountStateException implements Exception {
  /// 'account_merged' | 'account_cancelled' | 'user_not_found'
  final String errorCode;

  /// 若 errorCode='account_merged',这里是 target user_id;
  /// 客户端可引导用户切到这个 target 重新登录
  final String? mergedInto;

  final String message;

  AccountStateException({
    required this.errorCode,
    this.mergedInto,
    required this.message,
  });

  bool get isMerged => errorCode == 'account_merged';
  bool get isCancelled => errorCode == 'account_cancelled';

  @override
  String toString() => 'AccountStateException($errorCode${mergedInto != null ? ', mergedInto=$mergedInto' : ''}): $message';
}
