import 'dart:async';
import 'dart:convert';

import 'package:easy_auth/easy_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

String jwtExpiringAt(DateTime expiresAt) {
  String part(Map<String, Object> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'ES256'})}.${part({'exp': expiresAt.millisecondsSinceEpoch ~/ 1000})}.signature';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await EasyAuth().resetForTesting();
  });

  test(
    'refreshToken persists the replacement and emits session change',
    () async {
      final oldToken = jwtExpiringAt(
        DateTime.now().add(const Duration(hours: 1)),
      );
      final newToken = jwtExpiringAt(
        DateTime.now().add(const Duration(days: 1)),
      );
      SharedPreferences.setMockInitialValues({
        'easy_auth_token': oldToken,
        'easy_auth_user_info': jsonEncode({'user_id': 'user-1'}),
      });
      await EasyAuth().init(
        const EasyAuthConfig(
          baseUrl: 'https://auth.example.test',
          tenantId: 'nexterm',
          sceneId: 'app_native',
          enableAutoRefresh: false,
        ),
      );
      EasyAuth().setApiClientForTesting(
        EasyAuthApiClient(
          baseUrl: 'https://auth.example.test',
          tenantId: 'nexterm',
          sceneId: 'app_native',
          httpClient: MockClient((request) async {
            expect(request.url.path, '/login/refreshToken');
            expect(jsonDecode(request.body), {'token': oldToken});
            return http.Response(
              jsonEncode({
                'code': 0,
                'msg': 'success',
                'data': {'token': newToken},
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      );

      final changed = EasyAuth().onSessionChanged.first;
      expect(await EasyAuth().refreshToken(), newToken);
      expect((await changed)?.token, newToken);
      expect(EasyAuth().currentToken, newToken);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('easy_auth_token'), newToken);
    },
  );

  test('transient refresh failure preserves an unexpired session', () async {
    final token = jwtExpiringAt(DateTime.now().add(const Duration(hours: 1)));
    SharedPreferences.setMockInitialValues({
      'easy_auth_token': token,
      'easy_auth_user_info': jsonEncode({'user_id': 'user-1'}),
    });
    await EasyAuth().init(
      const EasyAuthConfig(
        baseUrl: 'https://auth.example.test',
        tenantId: 'nexterm',
        sceneId: 'app_native',
        enableAutoRefresh: false,
      ),
    );
    EasyAuth().setApiClientForTesting(
      EasyAuthApiClient(
        baseUrl: 'https://auth.example.test',
        tenantId: 'nexterm',
        sceneId: 'app_native',
        httpClient: MockClient((_) async => http.Response('unavailable', 503)),
      ),
    );

    await expectLater(EasyAuth().refreshToken(), throwsA(isA<Exception>()));
    expect(EasyAuth().currentToken, token);
    expect(EasyAuth().isLoggedIn, isTrue);
  });

  test('logout during refresh cannot resurrect the old session', () async {
    final token = jwtExpiringAt(DateTime.now().add(const Duration(hours: 1)));
    final replacement = jwtExpiringAt(
      DateTime.now().add(const Duration(days: 1)),
    );
    SharedPreferences.setMockInitialValues({
      'easy_auth_token': token,
      'easy_auth_user_info': jsonEncode({'user_id': 'user-1'}),
    });
    await EasyAuth().init(
      const EasyAuthConfig(
        baseUrl: 'https://auth.example.test',
        tenantId: 'nexterm',
        sceneId: 'app_native',
        enableAutoRefresh: false,
      ),
    );
    final refreshResponse = Completer<http.Response>();
    EasyAuth().setApiClientForTesting(
      EasyAuthApiClient(
        baseUrl: 'https://auth.example.test',
        tenantId: 'nexterm',
        sceneId: 'app_native',
        httpClient: MockClient((request) {
          if (request.url.path == '/login/refreshToken') {
            return refreshResponse.future;
          }
          if (request.url.path == '/login/logout') {
            return Future.value(http.Response('ok', 200));
          }
          return Future.value(http.Response('not found', 404));
        }),
      ),
    );

    final refreshing = EasyAuth().refreshToken();
    await Future<void>.delayed(Duration.zero);
    await EasyAuth().logout();
    refreshResponse.complete(
      http.Response(
        jsonEncode({
          'code': 0,
          'msg': 'success',
          'data': {'token': replacement},
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );

    expect(await refreshing, isNull);
    expect(EasyAuth().currentToken, isNull);
    expect(EasyAuth().isLoggedIn, isFalse);
  });
}
