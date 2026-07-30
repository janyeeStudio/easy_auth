import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// WebView登录对话框
class WebViewLoginDialog extends StatefulWidget {
  final String loginUrl;
  final Function(Map<String, dynamic>?) onResult;
  final String? channelId; // 登录渠道ID，用于确定回调URL
  final bool fullScreen; // 是否全屏显示

  const WebViewLoginDialog({
    Key? key,
    required this.loginUrl,
    required this.onResult,
    this.channelId,
    this.fullScreen = false,
  }) : super(key: key);

  @override
  State<WebViewLoginDialog> createState() => _WebViewLoginDialogState();
}

class _WebViewLoginDialogState extends State<WebViewLoginDialog> {
  bool _isLoading = true;
  String? _mainFrameError;
  bool _completed = false; // 防止重复调用onResult
  InAppWebViewController? _ctrl;
  Timer? _urlPoll;
  Timer? _loadingWatchdog;
  int _progress = 0;

  /// 诊断:记录每次回调命中 + URL,显示在 dialog 底部。截图给开发者定位问题。
  final List<String> _diag = [];
  void _trace(String tag, dynamic url) {
    final t = DateTime.now().toIso8601String().substring(11, 19); // HH:mm:ss
    final entry = '$t [$tag] ${url ?? '(null)'}';
    if (mounted) {
      setState(() {
        _diag.add(entry);
        if (_diag.length > 20) _diag.removeRange(0, _diag.length - 20);
      });
    }
    print('🔍 $entry');
  }

  @override
  void initState() {
    super.initState();
    // Start before the native WebView exists. WebView2 creation itself can
    // fail or stall when the runtime is missing; waiting for onWebViewCreated
    // alone would leave the dialog's loading indicator running forever.
    _armLoadingWatchdog();
  }

  @override
  void dispose() {
    _urlPoll?.cancel();
    _loadingWatchdog?.cancel();
    super.dispose();
  }

  /// 终极兜底:每 500ms 主动 poll 当前 URL。
  /// macOS WKWebView 上 form_post 触发的 navigation 在 InAppWebView 各种回调
  /// 上都不稳,只有主动读 controller.getUrl() 是可靠的。
  void _startUrlPolling() {
    _urlPoll?.cancel();
    _urlPoll = Timer.periodic(const Duration(milliseconds: 500), (t) async {
      if (_completed || !mounted) {
        t.cancel();
        return;
      }
      try {
        final uri = await _ctrl?.getUrl();
        if (uri == null) return;
        final url = uri.toString();
        if (_matchesCallback(url)) {
          t.cancel();
          if (!_completed) _handleCallback(url);
        }
      } catch (_) {
        /* poll 出错就跳过这次 */
      }
    });
  }

  /// 获取回调URL(主)。仅用于日志,实际匹配走 _matchesCallback。
  String _getCallbackUrl() => _callbackUrls().first;

  /// 兼容的回调 URL 前缀列表 — Apple Developer 上 Service ID 的 redirect_uri
  /// 历史上配过老的 `api.janyee.com/user/apple/callback`,后端迁到 auth 子域
  /// 后没改 Service ID,所以 Apple form_post 仍打到老路径。SDK 同时认两个。
  List<String> _callbackUrls() {
    final channelId = widget.channelId ?? 'google';
    if (channelId == 'apple') {
      return [
        'https://auth.janyee.com/apple/callback',
        'https://api.janyee.com/user/apple/callback', // 兼容 legacy
      ];
    }
    return [
      'https://auth.janyee.com/login/$channelId/callback',
      'https://api.janyee.com/user/login/$channelId/callback', // 兼容 legacy
    ];
  }

  bool _matchesCallback(String url) {
    for (final cb in _callbackUrls()) {
      if (url.startsWith(cb)) return true;
    }
    return false;
  }

  /// 根据平台类型获取合适的 User-Agent。
  ///
  /// WebView2 already reports its real Edge version. Overriding it with a
  /// stale Chromium version makes Apple's login page take a different code
  /// path from the browser that is actually rendering it.
  String? _getPlatformSpecificUserAgent() {
    final channelId = widget.channelId ?? 'google';
    if (channelId == 'apple') {
      if (Platform.isIOS) {
        return 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
      }
      if (Platform.isMacOS) {
        return 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15';
      }
      if (Platform.isWindows) {
        // Let WebView2 expose its actual Edge/Chromium version.
        return null;
      }
    }

    if (Platform.isAndroid) {
      return 'Mozilla/5.0 (Linux; Android 10; SM-G975F) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.120 Mobile Safari/537.36';
    }
    if (Platform.isMacOS) {
      return 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15';
    }
    if (Platform.isIOS) {
      return 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
    }
    if (Platform.isWindows) {
      return null;
    }
    // Windows / Linux 保持 Chrome UA
    return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.120 Safari/537.36';
  }

  /// 获取标题
  String _getTitle() {
    final channelId = widget.channelId ?? 'google';
    switch (channelId) {
      case 'apple':
        return 'Apple 登录';
      case 'google':
        return 'Google 登录';
      default:
        return '$channelId 登录';
    }
  }

  /// 关闭按钮处理 — 只触发 onResult,**不要自己 pop**
  ///
  /// dialog 的关闭统一交给 onResult 回调的调用方(例如 WebAppleLoginService
  /// 在拿到结果后 Navigator.of(dialogContext).pop())。这样保证全路径只
  /// pop 一次,不会把外层 EasyAuthLoginPage / 业务方根页面误 pop 导致黑屏。
  void _onCloseButton() {
    if (_completed) return;
    _completed = true;
    widget.onResult(null);
  }

  /// 系统返回键 / barrierDismissible 触发的关闭 — 同样只触发 onResult
  Future<bool> _onWillPop() async {
    if (!_completed) {
      _completed = true;
      widget.onResult(null);
    }
    return true; // 允许返回键真正关闭 dialog
  }

  @override
  Widget build(BuildContext context) {
    // WillPopScope 兜底 Android 系统返回键,确保 onResult 一定被触发 —
    // 否则调用方的 Completer 永远 await 不到结果,出现"卡死"。
    return WillPopScope(onWillPop: _onWillPop, child: _buildBody(context));
  }

  Widget _buildBody(BuildContext context) {
    // 根据fullScreen参数决定显示方式
    if (widget.fullScreen) {
      return Scaffold(
        appBar: AppBar(
          title: Text(_getTitle()),
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
          leading: IconButton(
            onPressed: _onCloseButton,
            icon: const Icon(Icons.close),
          ),
        ),
        body: _buildWebView(),
      );
    } else {
      return Dialog(
        child: Container(
          width: MediaQuery.of(context).size.width * 0.9,
          height: MediaQuery.of(context).size.height * 0.8,
          child: Column(
            children: [
              // 标题栏
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Colors.blue,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(8),
                    topRight: Radius.circular(8),
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      _getTitle(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: _onCloseButton,
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                  ],
                ),
              ),
              // WebView
              Expanded(child: _buildWebView()),
            ],
          ),
        ),
      );
    }
  }

  /// 构建WebView组件
  Widget _buildWebView() {
    final userAgent = _getPlatformSpecificUserAgent();
    final isWindows = Platform.isWindows;
    print('🔍 使用平台特定User-Agent: ${userAgent ?? '(WebView2 default)'}');

    return Stack(
      children: [
        InAppWebView(
          onWebViewCreated: (c) {
            _ctrl = c;
            _startUrlPolling();
            _armLoadingWatchdog();
          },
          initialUrlRequest: URLRequest(url: WebUri(widget.loginUrl)),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            javaScriptCanOpenWindowsAutomatically: true,
            userAgent: userAgent,
            allowsInlineMediaPlayback: true,
            mediaPlaybackRequiresUserGesture: false,
            // Apple uses target=_blank/window.open in parts of its web flow.
            // A second native WebView2 surface is not mounted by this dialog;
            // keeping navigation in the current surface avoids an about:blank
            // child texture being displayed as the login page.
            supportMultipleWindows: !isWindows,
            // 必须开 — 否则 shouldOverrideUrlLoading 不会回调。
            useShouldOverrideUrlLoading: true,
          ),
          onCreateWindow: (controller, createNavigationAction) async {
            final url = createNavigationAction.request.url?.toString();
            _trace('onCreateWindow', url);
            if (url != null && _matchesCallback(url) && !_completed) {
              _handleCallback(url);
              // The callback has been consumed by the Flutter layer. Tell
              // WebView2 not to navigate to the one-time OAuth callback.
              return true;
            }
            if (isWindows) {
              // flutter_inappwebview_windows loads the requested URL in the
              // current WebView when the client returns false. Calling
              // controller.loadUrl here as well starts the same navigation
              // twice and can leave Apple authorization on a blank surface.
              return false;
            }
            await controller.loadUrl(
              urlRequest: createNavigationAction.request,
            );
            return true;
          },
          // 跨平台最可靠的拦截点 — Android / iOS / macOS 全部触发。
          // onLoadStop 在 macOS WebView 实现上不稳定,
          // onNavigationResponse 在 macOS 上根本不调用 → 老版本卡死的根因。
          shouldOverrideUrlLoading: (controller, navAction) async {
            final url = navAction.request.url?.toString() ?? '';
            _trace('shouldOverride', url);
            if (_matchesCallback(url)) {
              if (!_completed) _handleCallback(url);
              return NavigationActionPolicy.CANCEL;
            }
            return NavigationActionPolicy.ALLOW;
          },
          onLoadStart: (controller, url) {
            _armLoadingWatchdog();
            if (mounted) {
              setState(() {
                _isLoading = true;
                _progress = 0;
                _mainFrameError = null;
              });
            }
            _trace('onLoadStart', url);
            final s = url?.toString();
            if (s != null && _matchesCallback(s) && !_completed) {
              _handleCallback(s);
            }
          },
          onUpdateVisitedHistory: (controller, url, androidIsReload) {
            _trace('onUpdateVisitedHistory', url);
            final s = url?.toString();
            if (s != null && _matchesCallback(s) && !_completed) {
              _handleCallback(s);
            }
          },
          onProgressChanged: (controller, progress) {
            _progress = progress;
            if (progress >= 80 && mounted) {
              _clearLoadingWatchdog();
              setState(() {
                _isLoading = false;
              });
            }
          },
          onLoadStop: (controller, url) {
            _clearLoadingWatchdog();
            if (mounted) {
              setState(() {
                _isLoading = false;
                _progress = 100;
              });
            }
            _trace('onLoadStop', url);
            final s = url?.toString();
            if (s != null && _matchesCallback(s) && !_completed) {
              _handleCallback(s);
            }
          },
          onReceivedError: (controller, request, error) {
            _clearLoadingWatchdog();
            if (mounted && request.isForMainFrame != false) {
              setState(() {
                _isLoading = false;
                _mainFrameError = error.description;
              });
            }
            _trace('onReceivedError', '${request.url} ${error.description}');
          },
          onReceivedHttpError: (controller, request, errorResponse) {
            if (mounted &&
                request.isForMainFrame != false &&
                (errorResponse.statusCode ?? 0) >= 400) {
              setState(() {
                _isLoading = false;
                _mainFrameError = '登录页面返回 HTTP ${errorResponse.statusCode}。';
              });
            }
            _trace(
              'onReceivedHttpError',
              '${request.url} ${errorResponse.statusCode}',
            );
          },
          onConsoleMessage: (controller, consoleMessage) {
            _trace('console', consoleMessage.message);
          },
        ),
        // 加载指示器
        if (_isLoading)
          IgnorePointer(
            child: Center(
              child: CircularProgressIndicator(
                value: _progress > 0 && _progress < 100
                    ? _progress / 100
                    : null,
              ),
            ),
          ),
        if (_mainFrameError != null)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.white,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off, size: 42),
                      const SizedBox(height: 12),
                      const Text(
                        'Apple 登录页面加载失败',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Text(_mainFrameError!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _retryMainFrame,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _retryMainFrame() async {
    if (!mounted) return;
    setState(() {
      _mainFrameError = null;
      _isLoading = true;
      _progress = 0;
    });
    _armLoadingWatchdog();
    await _ctrl?.reload();
  }

  void _armLoadingWatchdog() {
    _loadingWatchdog?.cancel();
    _loadingWatchdog = Timer(const Duration(seconds: 18), () {
      if (!mounted || _completed) return;
      setState(() {
        _isLoading = false;
        _mainFrameError = '登录页面加载超时，请检查网络后重试。';
      });
      _trace('loadingTimeout', widget.loginUrl);
    });
  }

  void _clearLoadingWatchdog() {
    _loadingWatchdog?.cancel();
    _loadingWatchdog = null;
  }

  void _handleCallback(String url) async {
    // 防止重复调用
    if (_completed) {
      print('⚠️ 回调已处理，跳过重复调用');
      return;
    }
    _completed = true;

    try {
      print('🔍 处理回调URL: $url');
      final uri = Uri.parse(url);
      final code = uri.queryParameters['code'];
      final state = uri.queryParameters['state'];
      final error = uri.queryParameters['error'];

      print('🔍 URL参数 - code: $code, state: $state, error: $error');
      print('🔍 所有查询参数: ${uri.queryParameters}');

      // 检查是否有错误
      if (error != null) {
        print('❌ Google OAuth错误: $error');
        // 只调 onResult,**不要自己 pop dialog** — 跟关闭按钮一样统一让
        // onResult 调用方负责 pop,避免双 pop 把外层页面也连带 pop 出现黑屏
        widget.onResult(null);
        return;
      }

      if (code != null && code.isNotEmpty) {
        print('✅ 获取到授权码: $code');

        // 直接返回回调URL，让EasyAuth调用后端API
        final result = {'callbackUrl': url, 'platform': 'web'};

        print('🔍 WebView返回回调URL: $result');

        // 返回结果，让调用方处理对话框关闭
        widget.onResult(result);
      } else {
        print('❌ 未获取到授权码，可能是用户取消了登录');
        widget.onResult(null);
      }
    } catch (e) {
      print('❌ 处理回调失败: $e');
      widget.onResult(null);
    }
  }
}
