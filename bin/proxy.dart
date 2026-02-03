import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

const _targetBaseHost = 'https://api.tholeapis.top';
const _targetQHost = 'https://api.thuhole.site';
const _targetQ2Host = 'https://api2.thuhole.site';
const _defaultToken = 'yIF4TBviCyGuPEoV';
const _userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/96.0.4664.93 Safari/537.36';

Future<void> main(List<String> args) async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;
  final token =
      (Platform.environment['THOLE_TOKEN'] ?? _defaultToken).trim();

  final handler = Pipeline().addMiddleware(_cors()).addHandler(
        (request) => _handleProxy(request, token),
      );

  final server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, port);
  // ignore: avoid_print
  print('Proxy running on http://${server.address.host}:${server.port}');
}

Future<Response> _handleProxy(Request request, String defaultToken) async {
  if (request.method != 'GET' && request.method != 'POST') {
    return Response(405, body: 'Only GET/POST is supported');
  }

  final original = request.url;
  final path = original.path;
  final isQ = path.startsWith('q/_api/');
  final isQ2 = path.startsWith('q2/_api/');
  final apiPrefix = _resolveApiPrefix(path);
  final targetPath = _stripPrefix(path, apiPrefix);
  final queryParameters = Map<String, String>.from(original.queryParameters);
  queryParameters.remove('token');
  final host = isQ
      ? _targetQHost
      : isQ2
          ? _targetQ2Host
          : _targetBaseHost;
  final baseUrl = '$host$apiPrefix';
  final targetUri = Uri.parse(baseUrl + targetPath).replace(
    queryParameters: queryParameters,
  );

  final token = (original.queryParameters['token'] ?? defaultToken).trim();
  if (token.isEmpty) {
    return Response(400, body: 'Missing token');
  }
  final bodyBytes = request.method == 'POST' ? await request.read().expand((b) => b).toList() : null;
  return _forwardRequest(
    targetUri,
    token: token,
    method: request.method,
    bodyBytes: bodyBytes,
    contentType: request.headers['content-type'],
  );
}

Future<Response> _forwardRequest(
  Uri target, {
  required String token,
  required String method,
  List<int>? bodyBytes,
  String? contentType,
}) async {
  final client = HttpClient();
  try {
    final outbound = await client.openUrl(method, target);
    outbound.headers.set('User-Agent', _userAgent);
    outbound.headers.set('User-Token', token);
    if (contentType != null && contentType.isNotEmpty) {
      outbound.headers.set('Content-Type', contentType);
    }
    if (bodyBytes != null && bodyBytes.isNotEmpty) {
      outbound.add(bodyBytes);
    }

    final inbound = await outbound.close();
    final responseBytes =
        await inbound.fold<List<int>>(<int>[], (buffer, chunk) {
      buffer.addAll(chunk);
      return buffer;
    });

    return Response(
      inbound.statusCode,
      body: responseBytes,
      headers: {
        'content-type': inbound.headers.contentType?.toString() ??
            'application/octet-stream',
      },
    );
  } finally {
    client.close();
  }
}

Middleware _cors() {
  return (innerHandler) {
    return (request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: _corsHeaders());
      }
      final response = await innerHandler(request);
      return response.change(headers: _corsHeaders());
    };
  };
}

Map<String, String> _corsHeaders() => const {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    };

String _resolveApiPrefix(String path) {
  const prefixes = [
    'q/_api/v2',
    'q/_api/v1',
    'q2/_api/v2',
    'q2/_api/v1',
    '_api/v2',
    '_api/v1',
  ];
  for (final prefix in prefixes) {
    if (path.startsWith(prefix)) {
      final parts = prefix.split('/');
      if (parts.length >= 3) {
        return '/${parts[1]}/${parts[2]}';
      }
      if (parts.length == 2) {
        return '/${parts[0]}/${parts[1]}';
      }
      break;
    }
  }
  return '/_api/v1';
}

String _stripPrefix(String path, String apiPrefix) {
  final candidates = [
    'q$apiPrefix',
    'q2$apiPrefix',
    apiPrefix.substring(1),
    apiPrefix,
  ];
  for (final prefix in candidates) {
    if (path.startsWith(prefix)) {
      return path.substring(prefix.length);
    }
  }
  return path;
}
