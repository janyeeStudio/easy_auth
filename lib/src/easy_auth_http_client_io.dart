import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

http.Client createEasyAuthHttpClient() {
  final client = HttpClient();
  client.findProxy = HttpClient.findProxyFromEnvironment;
  return IOClient(client);
}
