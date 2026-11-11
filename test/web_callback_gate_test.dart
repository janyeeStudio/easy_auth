import 'package:easy_auth/src/web_callback_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const callback =
      'https://auth.janyee.com/apple/callback?code=one-time&state=signed';

  WebCallbackGate gate() => WebCallbackGate(
    (url) => url.startsWith('https://auth.janyee.com/apple/callback'),
  );

  test('observing callback navigation does not complete it early', () {
    final value = gate();

    expect(value.observeNavigation(callback), isTrue);
    expect(value.completeFromPoll(callback, 'Sign in with Apple'), isFalse);
  });

  test('callback completes only after AnyLogin response has loaded', () {
    final value = gate();

    value.observeNavigation(callback);

    expect(value.completeAfterLoad(callback), isTrue);
  });

  test('poll fallback requires the AnyLogin callback document title', () {
    final value = gate();

    value.observeNavigation(callback);

    expect(value.completeFromPoll(callback, 'Apple 登录回调'), isTrue);
  });

  test('unrelated navigation never arms or completes the callback', () {
    final value = gate();
    const unrelated = 'https://appleid.apple.com/auth/authorize';

    expect(value.observeNavigation(unrelated), isFalse);
    expect(value.completeAfterLoad(unrelated), isFalse);
  });
}
