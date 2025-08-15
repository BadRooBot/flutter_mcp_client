import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'mcp_client.dart';

void main() {
  // Setup logging to console
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((rec) {
    // ignore: avoid_print
    print('[${rec.level.name}] ${rec.loggerName}: ${rec.message}');
  });
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MCP Client',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter run". You'll see
        // the application has a purple toolbar. Then, without quitting the app,
        // try changing the seedColor in the colorScheme below to Colors.green
        // and then invoke "hot reload" (save your changes or press the "hot
        // reload" button in a Flutter-supported IDE, or press "r" if you used
        // the command line to start the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        //
        // This works for code too, not just values: Most code changes can be
        // tested with just a hot reload.
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'MCP Client (Android primary)'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final _baseUrlCtrl = TextEditingController(text: 'https://mcp.semgrep.ai/sse');
  final _tokenCtrl = TextEditingController();
  McpClient? _client;
  bool _connecting = false;
  String _status = 'Disconnected';
  List<String> _tools = [];

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    _tokenCtrl.dispose();
    _client?.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_connecting) return;
    setState(() {
      _connecting = true;
      _status = 'Connecting...';
    });

    final headers = <String, String>{};
    final token = _tokenCtrl.text.trim();
    if (token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }

    final client = McpClient(
      baseSseUrl: _baseUrlCtrl.text.trim(),
      options: McpClientOptions(headers: headers),
    );
    try {
      await client.connect();
      final toolsRes = await client.listTools();
      final tools = <String>[];
      if (toolsRes is Map<String, dynamic>) {
        final list = toolsRes['tools'];
        if (list is List) {
          for (final t in list) {
            if (t is Map<String, dynamic>) {
              final name = t['name']?.toString();
              if (name != null) tools.add(name);
            }
          }
        }
      }
      setState(() {
        _client = client;
        _status = 'Connected (session: ${client.sessionId ?? 'n/a'})';
        _tools = tools;
      });
    } catch (e) {
      setState(() {
        _status = 'Failed: $e';
      });
      client.dispose();
    } finally {
      setState(() {
        _connecting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      appBar: AppBar(
        // TRY THIS: Try changing the color here to a specific color (to
        // Colors.amber, perhaps?) and trigger a hot reload to see the AppBar
        // change color while the other colors stay the same.
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _baseUrlCtrl,
              decoration: const InputDecoration(
                labelText: 'SSE URL',
                hintText: 'https://host/sse',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenCtrl,
              decoration: const InputDecoration(
                labelText: 'Authorization Bearer Token (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _connecting ? null : _connect,
                  icon: _connecting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link),
                  label: const Text('Connect & List Tools'),
                ),
                const SizedBox(width: 12),
                Text(
                  _status,
                  style: TextStyle(
                    color: _status.startsWith('Failed')
                        ? Colors.red
                        : Colors.green,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('Tools (${_tools.length}):', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: _tools.isEmpty
                    ? const Center(child: Text('No tools loaded'))
                    : ListView.separated(
                        itemCount: _tools.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) => ListTile(
                          leading: const Icon(Icons.build),
                          title: Text(_tools[i]),
                        ),
                      ),
              ),
            )
          ],
        ),
      ),
    );
  }
}
