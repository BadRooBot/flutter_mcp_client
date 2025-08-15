import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import 'transports/sse_transport.dart';

class McpClientOptions {
  final String clientName;
  final String clientVersion;
  final String protocolVersion; // default '2025-06-18'
  final Map<String, dynamic> capabilities;
  final Map<String, String> headers;

  const McpClientOptions({
    this.clientName = 'mcp-dart-client',
    this.clientVersion = '1.0.0',
    this.protocolVersion = '2025-06-18',
    this.capabilities = const {},
    this.headers = const {},
  });
}

class McpClient {
  final Logger _log = Logger('McpClient');
  final Uuid _uuid = const Uuid();

  final String baseSseUrl;
  final McpClientOptions options;

  late final SseTransport _transport;

  bool _connected = false;
  bool get isConnected => _connected;

  String? _sessionId;
  String? get sessionId => _sessionId;

  // pending id -> completer, meta
  final Map<String, _PendingRequest> _pending = {};
  Duration requestTimeout = const Duration(seconds: 60);

  McpClient({required this.baseSseUrl, McpClientOptions? options})
      : options = options ?? const McpClientOptions() {
    _transport = SseTransport(baseUrl: baseSseUrl, headers: this.options.headers);
  }

  Future<void> connect() async {
    _log.info('Connecting SSE: $baseSseUrl');

    await _transport.connect();

    // Listen to SSE events
    _transport.events.listen((evt) {
      try {
        _log.fine('SSE event: ${evt.event ?? '<default>'} id=${evt.id ?? '-'}');
        if ((evt.event ?? '').toLowerCase() == 'endpoint') {
          // endpoint text may be path or absolute URL
          final data = evt.data.trim();
          _transport.setMessagesEndpointFromEvent(data);
          // also try to get session from this endpoint
          _sessionId ??= _transport.sessionId;
        } else if ((evt.event ?? '').toLowerCase() == 'session') {
          // data may be json or plain text with session id
          final sid = _extractSessionId(evt.data);
          if (sid != null) {
            _sessionId = sid;
            _transport.sessionId = sid;
          }
        } else {
          // Treat as JSON-RPC data block(s)
          _handleIncoming(evt.data);
        }
      } catch (e, st) {
        _log.warning('Error handling SSE event: $e', e, st);
      }
    }, onError: (e, st) {
      _log.severe('SSE error: $e', e, st);
    });

    // If session id is not set yet, we wait a short moment for session/endpoint events
    // Not strictly required for some servers, but safer.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // Initialize MCP
    await _initializeWithFallback();

    _connected = true;
  }

  Future<void> _initializeWithFallback() async {
    final requested = options.protocolVersion;
    try {
      await initialize(protocolVersion: requested);
    } catch (e) {
      final msg = e.toString();
      if (requested != '2024-11-05' && msg.toLowerCase().contains('invalid request parameters')) {
        _log.info('Initialize failed with $requested, retry with 2024-11-05');
        await initialize(protocolVersion: '2024-11-05');
      } else {
        rethrow;
      }
    }
  }

  Future<void> initialize({required String protocolVersion}) async {
    final id = _nextId('init');
    final payload = {
      'jsonrpc': '2.0',
      'id': id,
      'method': 'initialize',
      'params': {
        'protocolVersion': protocolVersion,
        'clientInfo': {
          'name': options.clientName,
          'version': options.clientVersion,
        },
        'capabilities': options.capabilities,
      }
    };

    final result = await _sendRequest(id, payload);
    // adopt capabilities/session from result if present
    if (result is Map<String, dynamic>) {
      _sessionId = _sessionId ?? (result['session_id'] as String?) ?? (result['sessionId'] as String?);
      if (_sessionId != null) {
        _transport.sessionId = _sessionId;
      }
    }

    // notifications/initialized
    await sendNotification('notifications/initialized', {});
  }

  Future<dynamic> listTools() => sendRequest('tools/list', {});

  Future<dynamic> callTool(String name, Map<String, dynamic> arguments) =>
      sendRequest('tools/call', {
        'name': name,
        'arguments': arguments,
      });

  Future<dynamic> listResources() => sendRequest('resources/list', {});

  Future<dynamic> readResource(String uri) => sendRequest('resources/read', {
        'uri': uri,
      });

  Future<void> sendNotification(String method, Map<String, dynamic> params) async {
    final payload = {
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    };
    _log.fine('-> notification $method');
    await _transport.postJson(payload);
  }

  Future<dynamic> sendRequest(String method, Map<String, dynamic> params) async {
    final id = _nextId(method);
    final payload = {
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
      'id': id,
    };
    return _sendRequest(id, payload);
  }

  Future<dynamic> _sendRequest(String id, Map<String, dynamic> payload) async {
    final c = Completer<dynamic>();
    final timer = Timer(requestTimeout, () {
      if (!c.isCompleted) {
        _pending.remove(id);
        c.completeError(TimeoutException('Request $id timed out'));
      }
    });
    _pending[id] = _PendingRequest(completer: c, timer: timer, method: payload['method'] as String?);

    _log.fine('-> request ${payload['method']} id $id');
    await _transport.postJson(payload);

    return c.future;
  }

  void _handleIncoming(String data) {
    // Some streams may concatenate multiple JSON objects separated by newlines
    final chunks = const LineSplitter().convert(data);
    for (final chunk in chunks) {
      final trimmed = chunk.trim();
      if (trimmed.isEmpty) continue;
      try {
        final obj = jsonDecode(trimmed);
        _handleJson(obj);
      } catch (_) {
        // ignore garbage keep-alive lines
      }
    }
  }

  void _handleJson(dynamic obj) {
    if (obj is! Map<String, dynamic>) return;

    // JSON-RPC response
    if (obj.containsKey('id')) {
      final id = obj['id']?.toString();
      final pending = id != null ? _pending.remove(id) : null;
      if (pending == null) return;
      pending.timer.cancel();

      if (obj['error'] != null) {
        _log.warning('<- error ${pending.method ?? 'unknown'} id $id ${obj['error']}');
        pending.completer.completeError(Exception(obj['error']['message'] ?? 'Unknown error'));
      } else {
        _log.fine('<- result ${pending.method ?? 'unknown'} id $id');
        pending.completer.complete(obj['result']);
      }
      return;
    }

    // JSON-RPC notification
    if (obj['method'] is String) {
      _log.fine('<- notification ${obj['method']}');
      // You can add notification handling here if needed
    }
  }

  String? _extractSessionId(String data) {
    // Try JSON
    try {
      final j = jsonDecode(data);
      if (j is Map<String, dynamic>) {
        final s = (j['session_id'] as String?) ?? (j['sessionId'] as String?);
        if (s != null && s.isNotEmpty) return s;
      }
    } catch (_) {}

    // Try regex
    final m = RegExp(r'session[_-]?id\s*[:=]\s*"?([A-Za-z0-9_.:\-]+)"?').firstMatch(data);
    if (m != null) return m.group(1);

    return null;
  }

  String _nextId(String method) => '${method}_${_uuid.v4()}';

  void dispose() {
    for (final p in _pending.values) {
      p.timer.cancel();
      if (!p.completer.isCompleted) {
        p.completer.completeError(StateError('Client disposed'));
      }
    }
    _pending.clear();
    _transport.dispose();
  }
}

class _PendingRequest {
  final Completer<dynamic> completer;
  final Timer timer;
  final String? method;
  _PendingRequest({required this.completer, required this.timer, this.method});
}
