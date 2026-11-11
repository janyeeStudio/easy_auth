import 'dart:async';
import 'dart:convert';

import 'package:easy_auth/easy_auth.dart' hide PlatformException;
import 'package:easy_auth/src/easy_auth_exception.dart' as auth;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('com.aboutyou.dart_packages.sign_in_with_apple');
const _credential = {
  'type': 'appleid',
  'authorizationCode': 'private-apple-code',
  'identityToken': 'private-apple-id-token',
  'userIdentifier': 'apple-user',
};
const _sessionToken = 'private-app-session-token';

class _Navigation extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
  }
}

Future<BuildContext> _context(
  WidgetTester tester,
  _Navigation navigation,
) async {
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [navigation],
      home: Builder(
        builder: (value) {
          context = value;
          return const Scaffold(body: Text('Login'));
        },
      ),
    ),
  );
  return context;
}

http.Response _success() => http.Response(
  jsonEncode({
    'code': 0,
    'data': {
      'token': _sessionToken,
      'user_info': {'user_id': 'user-1'},
    },
  }),
  200,
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  var nativeCalls = 0;
  var apiCalls = 0;
  late Future<dynamic> Function() native;
  late Future<http.Response> Function(http.Request) exchange;

  setUp(() async {
    nativeCalls = apiCalls = 0;
    native = () async => _credential;
    exchange = (_) async => _success();
    SharedPreferences.setMockInitialValues({});
    await EasyAuth().init(
      const EasyAuthConfig(
        baseUrl: 'https://auth.test',
        tenantId: 'kiku_app',
        sceneId: 'app_native',
        enableAutoRefresh: false,
      ),
    );
    EasyAuth().setApiClientForTesting(
      EasyAuthApiClient(
        baseUrl: 'https://auth.test',
        tenantId: 'kiku_app',
        sceneId: 'app_native',
        httpClient: MockClient((request) async {
          apiCalls++;
          expectSync(request.url.path, '/login/directLogin');
          final body = jsonDecode(request.body) as Map;
          expectSync(body['channel_id'], 'apple');
          expectSync(
            body['channel_data']['id_token'],
            _credential['identityToken'],
          );
          return exchange(request);
        }),
      ),
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
      call,
    ) async {
      expectSync(call.method, 'performAuthorizationRequest');
      nativeCalls++;
      return native();
    });
  });

  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    await EasyAuth().resetForTesting();
  });

  const nativeErrors = {
    'canceled': 'USER_CANCELLED',
    'failed': 'APPLE_NATIVE_FAILED',
    'missing plugin': 'APPLE_NATIVE_UNAVAILABLE',
    'unknown': 'APPLE_NATIVE_UNKNOWN',
    '1000': 'APPLE_NATIVE_UNKNOWN',
    'invalidResponse': 'APPLE_NATIVE_INVALIDRESPONSE',
  };
  for (final failure in nativeErrors.keys) {
    testWidgets(
      'native $failure never opens Web and preserves typed failure',
      (tester) async {
        final navigation = _Navigation();
        final context = await _context(tester, navigation);
        native = () async {
          if (failure == 'missing plugin') {
            throw MissingPluginException('private-details');
          }
          throw PlatformException(
            code: failure == '1000' ? '1000' : 'authorization-error/$failure',
            message: 'cancel private-apple-id-token private-details',
          );
        };
        await expectLater(
          EasyAuth().loginWithApple(context),
          throwsA(
            isA<auth.PlatformException>()
                .having((e) => e.message, 'message', nativeErrors[failure])
                .having((e) => e.originalError, 'raw error', isNull),
          ),
        );
        await tester.pump();
        expect(nativeCalls, 1);
        expect(apiCalls, 0);
        expect(navigation.pushes, 1);
        expect(EasyAuth().currentToken, isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  for (final malformed in [
    'missing id token',
    'empty id token',
    'missing authorization code',
    'wrong response type',
    'null response',
  ]) {
    testWidgets(
      'native $malformed never exchanges or opens Web',
      (tester) async {
        final navigation = _Navigation();
        final context = await _context(tester, navigation);
        native = () async {
          final data = Map<String, String>.from(_credential);
          switch (malformed) {
            case 'missing id token':
              data.remove('identityToken');
            case 'empty id token':
              data['identityToken'] = '  ';
            case 'missing authorization code':
              data.remove('authorizationCode');
            case 'wrong response type':
              data['type'] = 'private-invalid-type';
            case 'null response':
              return null;
          }
          return data;
        };
        await expectLater(
          EasyAuth().loginWithApple(context),
          throwsA(
            isA<auth.EasyAuthException>()
                .having(
                  (e) => e.message,
                  'not cancellation',
                  isNot(contains('USER_CANCELLED')),
                )
                .having(
                  (e) => e.toString(),
                  'controlled error',
                  isNot(contains('private-')),
                )
                .having((e) => e.originalError, 'raw error', isNull),
          ),
        );
        expect(nativeCalls, 1);
        expect(apiCalls, 0);
        expect(navigation.pushes, 1);
        expect(EasyAuth().currentToken, isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  for (final status in [401, 403, 503, 42201]) {
    testWidgets(
      'backend $status remains controlled and never opens Web',
      (tester) async {
        final navigation = _Navigation();
        final context = await _context(tester, navigation);
        exchange = (_) async => http.Response(
          jsonEncode({
            'code': status,
            'msg': 'private-apple-id-token private-apple-code $_sessionToken',
          }),
          status < 600 ? status : 200,
        );
        final logs = <String>[];
        final pending = runZoned(
          () => EasyAuth().loginWithApple(context),
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, line) => logs.add(line),
          ),
        );
        await expectLater(
          pending,
          throwsA(
            isA<auth.AuthenticationException>()
                .having((e) => e.statusCode, 'status', status)
                .having(
                  (e) => e.message,
                  'controlled message',
                  contains('状态码 $status'),
                )
                .having(
                  (e) => e.toString(),
                  'no private fields',
                  isNot(contains('private-')),
                )
                .having((e) => e.originalError, 'raw error', isNull),
          ),
        );
        await tester.pump();
        expect(nativeCalls, 1);
        expect(apiCalls, 1);
        expect(navigation.pushes, 1);
        expect(EasyAuth().currentToken, isNull);
        expect(logs.join(), isNot(contains('private-')));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets(
    'successful native exchange saves session without credential logs',
    (tester) async {
      final navigation = _Navigation();
      final context = await _context(tester, navigation);
      final logs = <String>[];
      final result = await runZoned(
        () => EasyAuth().loginWithApple(context),
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => logs.add(line),
        ),
      );
      expect(result.isSuccess, isTrue);
      expect(EasyAuth().currentToken, _sessionToken);
      expect(EasyAuth().currentUser?.userId, 'user-1');
      expect(
        (await SharedPreferences.getInstance()).getString('easy_auth_token'),
        _sessionToken,
      );
      expect(nativeCalls, 1);
      expect(apiCalls, 1);
      expect(navigation.pushes, 1);
      expect(logs.join(), isNot(contains('private-')));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'SDK single flight covers both native sheet and server exchange',
    (tester) async {
      final navigation = _Navigation();
      final context = await _context(tester, navigation);
      final nativeGate = Completer<Map<String, String>>();
      final exchangeGate = Completer<http.Response>();
      native = () => nativeGate.future;
      exchange = (_) => exchangeGate.future;
      final first = EasyAuth().loginWithApple(context);
      final second = EasyAuth().loginWithApple(context);
      expect(identical(first, second), isTrue);
      await tester.pump();
      expect(nativeCalls, 1);
      expect(apiCalls, 0);
      nativeGate.complete(_credential);
      await tester.pump();
      expect(apiCalls, 1);
      expect(identical(first, EasyAuth().loginWithApple(context)), isTrue);
      exchangeGate.complete(_success());
      final results = await Future.wait([first, second]);
      expect(results.every((r) => r.isSuccess), isTrue);
      native = () async => _credential;
      exchange = (_) async => _success();
      await EasyAuth().loginWithApple(context);
      expect(nativeCalls, 2);
      expect(apiCalls, 2);
      expect(navigation.pushes, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'cancel releases single flight for a deliberate new attempt',
    (tester) async {
      final navigation = _Navigation();
      final context = await _context(tester, navigation);
      native = () async =>
          throw PlatformException(code: 'authorization-error/canceled');
      await expectLater(
        EasyAuth().loginWithApple(context),
        throwsA(isA<auth.PlatformException>()),
      );
      native = () async => _credential;
      expect((await EasyAuth().loginWithApple(context)).isSuccess, isTrue);
      expect(nativeCalls, 2);
      expect(apiCalls, 1);
      expect(navigation.pushes, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'network error does not expose raw credentials or open Web',
    (tester) async {
      final navigation = _Navigation();
      final context = await _context(tester, navigation);
      exchange = (_) async =>
          throw http.ClientException('private-apple-id-token');
      await expectLater(
        EasyAuth().loginWithApple(context),
        throwsA(
          isA<auth.AuthenticationException>()
              .having(
                (e) => e.message,
                'controlled message',
                'Apple 登录暂时无法完成，请稍后重试',
              )
              .having((e) => e.originalError, 'raw error', isNull),
        ),
      );
      expect(navigation.pushes, 1);
      expect(EasyAuth().currentToken, isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
