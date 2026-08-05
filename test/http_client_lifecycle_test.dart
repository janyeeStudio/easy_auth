import 'dart:io';

import 'package:easy_auth/easy_auth.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingHttpOverrides extends HttpOverrides {
  int clientsCreated = 0;
  int proxyLookups = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clientsCreated += 1;
    return super.createHttpClient(context);
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    proxyLookups += 1;
    return 'DIRECT';
  }
}

void main() {
  test('default API client reuses one proxy-aware HttpClient', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        '{"code":0,"data":{"tenant_id":"nexterm",'
        '"tenant_name":"NexTerm","supported_channels":[]}}',
      );
      await request.response.close();
    });

    final overrides = _CountingHttpOverrides();
    await HttpOverrides.runWithHttpOverrides(() async {
      final api = EasyAuthApiClient(
        baseUrl: 'http://${server.address.host}:${server.port}',
        tenantId: 'nexterm',
        sceneId: 'app_native',
      );
      await api.getTenantConfig();
      await api.getTenantConfig();
      api.close();
    }, overrides);

    expect(overrides.clientsCreated, 1);
    expect(overrides.proxyLookups, greaterThan(0));
  });
}
