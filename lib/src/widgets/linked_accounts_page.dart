import 'package:flutter/material.dart';
import '../easy_auth_core.dart';
import '../easy_auth_models.dart';

// ============================================================================
// 绑定列表页 + 冲突解决对话框 + 二次确认对话框
// ============================================================================
//
// 用法:
//   Navigator.push(ctx, MaterialPageRoute(builder: (_) => const LinkedAccountsPage()))
//
// 页面会:
//   - 拉 EasyAuth().myChannels() 显示已绑定列表
//   - 提供 "+ 添加登录方式" 按钮(弹底部菜单选 sms/email/wechat/apple/google)
//   - 每条提供解绑按钮(后端会拦"最后一个")
//   - 绑定冲突时弹 BindConflictDialog 让用户选合并方向(双向)
//   - 绑定前弹 BindConfirmDialog 二次确认(per 设计决策)
//
// 真正去拿 sms code / google authcode / apple idToken 的流程依赖项目
// 自己的 channel SDK 调用,这个页面只在拿到 channel_data 后调
// EasyAuth().bindChannel(...) 触发绑定。可以接 EasyAuthLoginPage 复用现有
// 渠道收集 UI(把"登录"改成"绑定"按钮)。这里给一个最简的 demo:
//   - sms / email:就地输入手机号 + 验证码
//   - wechat/apple/google:用户需自行接入(回调里调 bindChannelXxx)
// ============================================================================

class LinkedAccountsPage extends StatefulWidget {
  /// 自定义"添加登录方式"的入口 — 调用方提供给定 channelId 弹自己的收集 UI,
  /// 拿到 channel_data 后调 [onBind] 提交。返回 null 表示用户取消。
  ///
  /// 不提供时,sms/email 用内置最简 dialog;wechat/apple/google 走 SDK 默认路径
  /// (若调用方没接 google 平台 SDK,会抛 UnimplementedError —— UI 友好提示)。
  final Future<BindResult?> Function(
    BuildContext context,
    String channelId,
  )? customBindFlow;

  /// 标题,默认 "登录方式管理"
  final String title;

  const LinkedAccountsPage({super.key, this.customBindFlow, this.title = '登录方式管理'});

  @override
  State<LinkedAccountsPage> createState() => _LinkedAccountsPageState();
}

class _LinkedAccountsPageState extends State<LinkedAccountsPage> {
  List<LinkedChannel> _channels = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await EasyAuth().myChannels();
      if (mounted) {
        setState(() {
          _channels = list;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _onUnbind(LinkedChannel ch) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('解绑登录方式'),
        content: Text('确定解绑 "${ch.channelName}" 吗?\n解绑后将无法用该方式登录。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('解绑'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await EasyAuth().unbindChannel(ch.channelId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已解绑')));
      }
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('解绑失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _onAddChannel() async {
    final channelId = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('选择登录方式', style: TextStyle(fontWeight: FontWeight.bold))),
            const Divider(height: 1),
            const _ChannelOption(channelId: 'sms', label: '短信验证码', icon: Icons.sms),
            const _ChannelOption(channelId: 'email', label: '邮箱验证码', icon: Icons.email),
            if (EasyAuth().isLoginChannelEnabled('wechat'))
              const _ChannelOption(channelId: 'wechat', label: '微信', icon: Icons.chat),
            const _ChannelOption(channelId: 'apple', label: 'Apple ID', icon: Icons.apple),
            const _ChannelOption(channelId: 'google', label: 'Google', icon: Icons.g_mobiledata),
          ],
        ),
      ),
    );
    if (channelId == null || !mounted) return;

    // 已绑就跳过(也可以让后端 already_bound 兜底)
    if (_channels.any((c) => c.channelId == channelId)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('该方式已绑定: $channelId')),
        );
      }
      return;
    }

    // 二次确认 (per 设计决策)
    final confirmed = await BindConfirmDialog.show(context, channelId);
    if (confirmed != true || !mounted) return;

    BindResult? result;
    try {
      if (widget.customBindFlow != null) {
        result = await widget.customBindFlow!(context, channelId);
        if (result == null) return; // 用户取消
      } else if (channelId == 'sms' || channelId == 'email') {
        result = await _runBuiltinVerificationBind(channelId);
        if (result == null) return;
      } else {
        // 各 native SDK 需要项目自己集成 — 提示
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$channelId 绑定需要项目集成原生 SDK,请提供 customBindFlow'),
              duration: const Duration(seconds: 4),
            ),
          );
        }
        return;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('绑定失败: $e'), backgroundColor: Colors.red),
        );
      }
      return;
    }

    // 处理 BindResult 三态
    if (!mounted) return;
    switch (result) {
      case BindOk():
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('绑定成功')));
        await _reload();
      case BindAlreadyBound():
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已经绑过了')));
        await _reload();
      case BindConflict(:final conflictToken, :final other, :final current):
        final action = await BindConflictDialog.show(context, other: other, current: current);
        if (action != null && mounted) {
          try {
            final resolved = await EasyAuth().resolveBindConflict(
              conflictToken: conflictToken,
              action: action,
            );
            if (!mounted) return;
            if (resolved is BindOk) {
              if (action == ResolveAction.meIntoOther) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已合并到对方账号,请重新登录')),
                );
                // 当前 token 已失效,清本地 session
                await EasyAuth().logout();
                if (mounted) Navigator.pop(context);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('合并完成')));
                await _reload();
              }
            } else if (resolved is BindError) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('合并失败: ${resolved.message}'), backgroundColor: Colors.red),
              );
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('合并失败: $e'), backgroundColor: Colors.red),
              );
            }
          }
        }
      case BindError(:final message):
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: Colors.red),
        );
    }
  }

  /// 内置最简的 sms/email 绑定流程(发码 + 输入码),不依赖项目 UI
  Future<BindResult?> _runBuiltinVerificationBind(String channelId) async {
    final ctrl1 = TextEditingController();
    final ctrl2 = TextEditingController();
    final isSms = channelId == 'sms';

    bool? sent = false;
    sent = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) {
        bool sending = false;
        return AlertDialog(
          title: Text(isSms ? '绑定手机号' : '绑定邮箱'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl1,
                keyboardType: isSms ? TextInputType.phone : TextInputType.emailAddress,
                decoration: InputDecoration(labelText: isSms ? '手机号' : '邮箱'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: ctrl2,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '验证码'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: sending
                        ? null
                        : () async {
                            final v = ctrl1.text.trim();
                            if (v.isEmpty) return;
                            setSt(() => sending = true);
                            try {
                              if (isSms) {
                                await EasyAuth().apiClient.sendSMSCode(v);
                              } else {
                                await EasyAuth().apiClient.sendEmailCode(v);
                              }
                              if (ctx.mounted) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(content: Text('已发送')),
                                );
                              }
                            } catch (e) {
                              if (ctx.mounted) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  SnackBar(content: Text('发送失败: $e')),
                                );
                              }
                            } finally {
                              setSt(() => sending = false);
                            }
                          },
                    child: const Text('发送'),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('绑定')),
          ],
        );
      }),
    );
    if (sent != true) return null;
    final v = ctrl1.text.trim();
    final code = ctrl2.text.trim();
    if (v.isEmpty || code.isEmpty) return null;
    return isSms
        ? EasyAuth().bindChannelSms(phoneNumber: v, code: code)
        : EasyAuth().bindChannelEmail(email: v, code: code);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _reload,
            tooltip: '刷新',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, size: 48, color: Colors.red),
                        const SizedBox(height: 8),
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: _reload, child: const Text('重试')),
                      ],
                    ),
                  ),
                )
              : _channels.isEmpty
                  ? const Center(child: Text('暂无绑定的登录方式'))
                  : ListView.separated(
                      itemCount: _channels.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final c = _channels[i];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                            child: Text(c.channelId.isNotEmpty ? c.channelId[0].toUpperCase() : '?'),
                          ),
                          title: Text(c.channelName),
                          subtitle: Text(c.channelUserIdMasked),
                          trailing: IconButton(
                            icon: const Icon(Icons.link_off, color: Colors.red),
                            onPressed: () => _onUnbind(c),
                            tooltip: '解绑',
                          ),
                        );
                      },
                    ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _onAddChannel,
        icon: const Icon(Icons.add),
        label: const Text('添加登录方式'),
      ),
    );
  }
}

class _ChannelOption extends StatelessWidget {
  final String channelId;
  final String label;
  final IconData icon;
  const _ChannelOption({required this.channelId, required this.label, required this.icon});
  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      onTap: () => Navigator.pop(context, channelId),
    );
  }
}

// ============================================================================
// 二次确认对话框 (绑定前)
// ============================================================================

class BindConfirmDialog {
  static Future<bool?> show(BuildContext context, String channelId) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('确认绑定'),
        content: Text('即将把 "$channelId" 渠道绑定到当前账号。绑定后,使用该渠道登录会进入此账号。\n\n是否继续?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确定绑定')),
        ],
      ),
    );
  }
}

// ============================================================================
// 冲突解决对话框 (双向合并)
// ============================================================================

class BindConflictDialog {
  /// 返回用户选的 ResolveAction;返回 null = 取消
  static Future<ResolveAction?> show(
    BuildContext context, {
    required AccountSummary other,
    AccountSummary? current,
  }) {
    return showDialog<ResolveAction>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BindConflictDialogContent(other: other, current: current),
    );
  }
}

class _BindConflictDialogContent extends StatelessWidget {
  final AccountSummary other;
  final AccountSummary? current;
  const _BindConflictDialogContent({required this.other, this.current});

  Widget _accountCard(BuildContext ctx, AccountSummary a, String label, Color color) {
    return Card(
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (a.avatar != null && a.avatar!.isNotEmpty)
                  CircleAvatar(backgroundImage: NetworkImage(a.avatar!), radius: 18)
                else
                  CircleAvatar(backgroundColor: color, radius: 18, child: const Icon(Icons.person, color: Colors.white)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: Theme.of(ctx).textTheme.labelSmall),
                      Text(
                        a.nickname?.isNotEmpty == true ? a.nickname! : '(未设置昵称)',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(a.userIdMasked, style: Theme.of(ctx).textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: a.boundChannels
                  .map((c) => Chip(label: Text(c), padding: EdgeInsets.zero, visualDensity: VisualDensity.compact))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('账号合并'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('该登录方式已经在另一个账号下注册过了。如果都是你本人的,可以合并:'),
            const SizedBox(height: 12),
            if (current != null) ...[
              _accountCard(context, current!, '当前账号', Colors.blue),
              const SizedBox(height: 8),
            ],
            _accountCard(context, other, '已存在账号', Colors.orange),
            const SizedBox(height: 16),
            const Text(
              '合并不可撤销 (但 7 天内可申请回滚)。被吞掉的一方所有渠道 / 数据会迁到留下的一方。',
              style: TextStyle(color: Colors.red, fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, ResolveAction.meIntoOther),
          child: const Text('保留对方,丢弃当前'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, ResolveAction.otherIntoMe),
          child: const Text('保留当前,吞掉对方'),
        ),
      ],
    );
  }
}
