import 'dart:async';
import 'dart:convert';

import 'package:easy_auth/easy_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _initialize() async {
  SharedPreferences.setMockInitialValues({
    'easy_auth_token': 'old-token',
    'easy_auth_user_info': jsonEncode({'user_id': 'alice'}),
  });
  await EasyAuth().init(
    const EasyAuthConfig(
      baseUrl: 'https://auth.test',
      tenantId: 'kiku_app',
      sceneId: 'app_native',
      enableAutoRefresh: false,
    ),
  );
}

void _client(Future<http.Response> Function(http.Request) handler) {
  EasyAuth().setApiClientForTesting(
    EasyAuthApiClient(
      baseUrl: 'https://auth.test',
      tenantId: 'kiku_app',
      sceneId: 'app_native',
      httpClient: MockClient(handler),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => EasyAuth().resetForTesting());

  for (final nextOwner in <String?>[null, 'alice', 'bob']) {
    test('conditional logout with replacement owner $nextOwner', () async {
      await _initialize();
      final started = Completer<void>();
      final response = Completer<http.Response>();
      _client((request) async {
        if (request.url.path == '/login/logout') {
          expect(request.url.queryParameters['token'], 'old-token');
          started.complete();
          return response.future;
        }
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'token': 'new-token',
              'user_info': {'user_id': nextOwner},
            },
          }),
          200,
        );
      });
      final events = <AuthSession?>[];
      final subscription = EasyAuth().onSessionChanged.listen(events.add);
      addTearDown(subscription.cancel);
      final pending = EasyAuth().logoutIfSessionMatches(
        expectedUserId: 'alice',
        expectedToken: 'old-token',
      );
      await started.future;
      if (nextOwner != null) {
        await EasyAuth().loginWithEmail(
          email: '$nextOwner@example.test',
          verificationCode: 'test',
        );
      }
      response.complete(http.Response('ok', 200));
      expect(await pending, nextOwner == null);
      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      if (nextOwner == null) {
        expect(EasyAuth().currentToken, isNull);
        expect(prefs.getString('easy_auth_token'), isNull);
        expect(prefs.getString('easy_auth_user_info'), isNull);
        expect(events, [null]);
      } else {
        expect(EasyAuth().currentUser?.userId, nextOwner);
        expect(EasyAuth().currentToken, 'new-token');
        expect(prefs.getString('easy_auth_token'), 'new-token');
        expect(
          jsonDecode(prefs.getString('easy_auth_user_info')!)['user_id'],
          nextOwner,
        );
        expect(events.any((event) => event == null), isFalse);
      }
    });
  }

  for (final mismatch in ['owner', 'token']) {
    test('mismatched $mismatch never calls logout API', () async {
      await _initialize();
      var calls = 0;
      _client((_) async {
        calls++;
        return http.Response('ok', 200);
      });
      expect(
        await EasyAuth().logoutIfSessionMatches(
          expectedUserId: mismatch == 'owner' ? 'bob' : 'alice',
          expectedToken: mismatch == 'token' ? 'other-token' : 'old-token',
        ),
        isFalse,
      );
      expect(calls, 0);
      expect(EasyAuth().currentToken, 'old-token');
    });
  }

  test(
    'remote logout failure still clears only the matching local session',
    () async {
      await _initialize();
      _client((_) async => http.Response('unavailable', 503));
      expect(
        await EasyAuth().logoutIfSessionMatches(
          expectedUserId: 'alice',
          expectedToken: 'old-token',
        ),
        isTrue,
      );
      expect(EasyAuth().currentToken, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('easy_auth_token'), isNull);
    },
  );
}
