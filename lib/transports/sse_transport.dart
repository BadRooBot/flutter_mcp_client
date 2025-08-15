import 'dart:async';
import 'dart:convert';

import 'package:eventsource/eventsource.dart' as es;
import 'package:http/http.dart' as http;

class SseEvent {
  final String? event;
  final String? id;
  final String data;
  SseEvent({this.event, this.id, required this.data});
}

/// Minimal SSE transport that:
/// - Connects to an SSE endpoint (e.g., https://host/sse)
/// - Emits SseEvent for each received event
/// - Posts JSON-RPC requests to a messages endpoint (resolved via `endpoint` event or {base}/messages)
class SseTransport {
  final Uri sseUri;
  final Map<String, String> headers;
  final http.Client _client;
  es.EventSource? _es;
  StreamSubscription? _esSub;

  final _eventCtrl = StreamController<SseEvent>.broadcast();
  Stream<SseEvent> get events => _eventCtrl.stream;

  Uri? _messagesUri; // Full absolute messages endpoint
  String? sessionId;

  SseTransport({required String baseUrl, Map<String, String>? headers})
      : sseUri = Uri.parse(baseUrl),
        headers = headers ?? const {},
        _client = http.Client();

  Future<void> connect() async {
    // Try eventsource package first (works on web and VM)
    try {
      _es = await es.EventSource.connect(sseUri.toString(), headers: headers);
      _esSub = _es!.listen((event) {
        final data = event.data ?? '';
        final e = SseEvent(event: event.event, id: event.id, data: data);
        _eventCtrl.add(e);
      }, onError: (e, st) {
        _eventCtrl.addError(e, st);
      }, onDone: () {
        _eventCtrl.close();
      });
      return; // success
    } catch (_) {
      // Fallback to manual HTTP streaming
    }

    // Open SSE stream via HTTP as a fallback (non-web)
    final request = http.Request('GET', sseUri);
    request.headers.addAll({
      'Accept': 'text/event-stream',
      ...headers,
    });

    final streamed = await _client.send(request);

    // Parse SSE lines: bytes -> String lines
    // We chain transforms instead of using fused() for compatibility.
    final lineStream = streamed.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter()); // we will re-assemble events on blank lines

    final buffer = <String>[];
    String? currentEvent;
    String? currentId;

    void flushEvent() {
      if (buffer.isEmpty) return;
      final data = buffer.join('\n');
      final evt = SseEvent(event: currentEvent, id: currentId, data: data);
      _eventCtrl.add(evt);
      buffer.clear();
      currentEvent = null;
      currentId = null;
    }

    lineStream.listen((line) {
      if (line.isEmpty) {
        // end of event
        flushEvent();
        return;
      }
      if (line.startsWith('event:')) {
        currentEvent = line.substring(6).trim();
      } else if (line.startsWith('id:')) {
        currentId = line.substring(3).trim();
      } else if (line.startsWith('data:')) {
        buffer.add(line.substring(5).trim());
      } else {
        // Continuation or comment - ignore or append
      }
    }, onError: (e, st) {
      _eventCtrl.addError(e, st);
    }, onDone: () {
      // stream closed
      _eventCtrl.close();
    });
  }

  /// Update messages endpoint from a relative or absolute path received via SSE `endpoint` event.
  void setMessagesEndpointFromEvent(String endpointPath) {
    final trimmed = endpointPath.trim();
    Uri endpointUri;
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      endpointUri = Uri.parse(trimmed);
    } else {
      // Resolve relative to base origin (strip trailing /sse)
      final base = _baseOriginForMessages();
      endpointUri = Uri.parse(base + (trimmed.startsWith('/') ? trimmed : '/$trimmed'));
    }
    _messagesUri = endpointUri;

    // Extract session_id from query if present
    final sid = endpointUri.queryParameters['session_id'];
    if (sid != null && sid.isNotEmpty) {
      sessionId = sid;
    }
  }

  String _baseOriginForMessages() {
    // remove trailing /sse if present
    final s = sseUri.toString();
    final withoutSse = s.replaceFirst(RegExp(r'/sse/?$'), '');
    return withoutSse;
  }

  /// Sends a JSON-RPC request/notification to the messages endpoint.
  /// Responses will arrive through the SSE stream.
  Future<void> postJson(Map<String, dynamic> payload) async {
    final endpoint = _messagesUri ?? Uri.parse('${_baseOriginForMessages()}/messages/');

    // Ensure session_id is present in query
    Uri finalUri = endpoint;
    final hasSid = finalUri.queryParameters.containsKey('session_id');
    if (!hasSid && sessionId != null) {
      finalUri = finalUri.replace(queryParameters: {
        ...finalUri.queryParameters,
        'session_id': sessionId!,
      });
    }

    final body = jsonEncode({
      'session_id': sessionId, // include for compatibility if server expects it in body too
      ...payload,
    });

    final resp = await _client.post(
      finalUri,
      headers: {
        'Content-Type': 'application/json',
        ...headers,
      },
      body: body,
    );

    if (resp.statusCode >= 400) {
      throw Exception('POST ${finalUri.toString()} failed: ${resp.statusCode} ${resp.body}');
    }
  }

  void dispose() {
    try {
      _esSub?.cancel();
    } catch (_) {}
    _client.close();
  }
}
