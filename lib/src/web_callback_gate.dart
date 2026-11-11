typedef CallbackUrlMatcher = bool Function(String url);

/// Holds a provider callback until AnyLogin has processed the callback request.
///
/// The authorization URL alone is not enough. AnyLogin validates the state
/// cookie and records the one-time authorization code while serving its
/// callback document. Consumers may exchange the code only after that request
/// has completed.
class WebCallbackGate {
  WebCallbackGate(this._matchesCallback);

  final CallbackUrlMatcher _matchesCallback;
  String? _pendingUrl;

  bool observeNavigation(String url) {
    if (!_matchesCallback(url)) return false;
    _pendingUrl = url;
    return true;
  }

  bool completeAfterLoad(String url) {
    return _pendingUrl != null && _matchesCallback(url);
  }

  bool completeFromPoll(String url, String? title) {
    if (_pendingUrl == null || !_matchesCallback(url)) return false;
    return title?.contains('登录回调') == true;
  }

  void reset() {
    _pendingUrl = null;
  }
}
