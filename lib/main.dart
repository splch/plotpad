import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:isar/isar.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:llama_sdk/llama_sdk.dart'
    if (dart.library.html) 'package:llama_sdk/llama_sdk.web.dart';

import 'models/sheet.dart';

/// ---------------- Isar & providers ----------------

final isarProvider = Provider<Isar>((_) => throw UnimplementedError());

final sheetListProvider = StreamProvider.autoDispose<List<Sheet>>(
  (ref) => ref.watch(isarProvider).sheets.where().watch(fireImmediately: true),
);

final searchQueryProvider = StateProvider<String>((_) => '');

final filteredSheetsProvider = Provider.autoDispose<List<Sheet>>((ref) {
  final query = ref.watch(searchQueryProvider).toLowerCase();
  final sheets = ref.watch(sheetListProvider).value ?? const <Sheet>[];
  if (query.isEmpty) return sheets;
  return sheets
      .where(
        (s) =>
            s.name.toLowerCase().contains(query) ||
            s.tags.any((t) => t.toLowerCase().contains(query)),
      )
      .toList();
});

final sheetControllerProvider = Provider.autoDispose<SheetController>(
  (ref) => SheetController(ref.read(isarProvider)),
);

/// ---------------- Sheet controller ----------------

class SheetController {
  SheetController(this._isar) : _storage = const FlutterSecureStorage();

  final Isar _isar;
  final FlutterSecureStorage _storage;

  /* -------- encryption helpers -------- */

  static const _pbkdfRounds = 10000;

  Future<Uint8List> _deriveKey(String password, List<int> salt) async {
    final pbkdf2 = crypto.Pbkdf2(
      macAlgorithm: crypto.Hmac.sha256(),
      iterations: _pbkdfRounds,
      bits: 256,
    );
    final secretKey = await pbkdf2.deriveKey(
      secretKey: crypto.SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    return Uint8List.fromList(await secretKey.extractBytes());
  }

  enc.Encrypter _encrypter(Uint8List keyBytes) =>
      enc.Encrypter(enc.AES(enc.Key(keyBytes), mode: enc.AESMode.cbc));

  Future<void> setPassword(Sheet sheet, {required String password}) async {
    if (sheet.csvContent.trim().isEmpty) return;

    // 1. derive key with random salt
    final salt = Uint8List.fromList(
      List<int>.generate(16, (_) => Random.secure().nextInt(256)),
    );
    final keyBytes = await _deriveKey(password, salt);

    // 2. random IV
    final iv = enc.IV.fromSecureRandom(16);

    // 3. encrypt
    final cipher =
        _encrypter(keyBytes).encrypt(sheet.csvContent, iv: iv).base64;

    // 4. store salt & iv (no key) in secure storage
    final payload = jsonEncode({
      'salt': base64Encode(salt),
      'iv': base64Encode(iv.bytes),
    });
    final keyName =
        'sheet-${sheet.id}-${DateTime.now().millisecondsSinceEpoch}';
    await _storage.write(key: keyName, value: payload);

    // 5. persist
    await _isar.write((isar) {
      sheet
        ..isEncrypted = true
        ..csvContent = cipher
        ..passwordKeyName = keyName;
      isar.sheets.put(sheet);
    });
  }

  Future<String?> unlock(Sheet sheet, String password) async {
    if (!sheet.isEncrypted || sheet.passwordKeyName == null) {
      return sheet.csvContent;
    }

    final payloadStr = await _storage.read(key: sheet.passwordKeyName!);
    if (payloadStr == null) return null;
    final payload = jsonDecode(payloadStr) as Map<String, dynamic>;
    final salt = base64Decode(payload['salt'] as String);
    final iv = enc.IV(base64Decode(payload['iv'] as String));

    final keyBytes = await _deriveKey(password, salt);
    try {
      return _encrypter(
        keyBytes,
      ).decrypt(enc.Encrypted.fromBase64(sheet.csvContent), iv: iv);
    } on ArgumentError {
      // wrong key (bad password) or corrupted ciphertext
      return null;
    }
  }

  Future<void> updateCsv(Sheet sheet, String csv) async {
    if (sheet.isEncrypted) return; // disabled while encrypted
    await _isar.write((isar) {
      sheet.csvContent = csv;
      isar.sheets.put(sheet);
    });
  }

  /* -------- LLM model helpers -------- */

  static Future<String> _ensureModel() async {
    final data = await rootBundle.load('assets/models/llama-3b.gguf');
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'llama-3b.gguf');

    final file = File(path);
    if (!await file.exists()) {
      await file.create(recursive: true);
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return path;
  }

  Future<Llama> _loadLlama() async {
    _llama ??= Llama(
      LlamaController(
        modelPath: await _ensureModel(),
        nCtx: 1024,
        nBatch: 512,
        greedy: true,
      ),
    );
    return _llama!;
  }

  Llama? _llama;

  /* -------- chart generation -------- */

  Future<List<ChartSpec>> generateCharts(Sheet sheet) async {
    final csvText = sheet.csvContent.replaceAll(r'\n', '\n');
    final rows = const CsvToListConverter(eol: '\n').convert(csvText);
    if (rows.length < 3) return [];

    final llama = await _loadLlama();

    final sample = rows.take(21).map((r) => r.join(',')).join('\n');
    final prompt = '''
Return **only** a JSON array of chart specs.
Prefer: [{"type":"scatter","x":"ColA","y":"ColB"}, …]
If array is flat like ["scatter","ColA","ColB", …] ensure each triple is (type,x,y).
Use exact column headers. No prose, no markdown.
CSV:
```csv
$sample
```''';

    final tokens = llama.prompt([UserLlamaMessage(prompt)]);
    final buf = StringBuffer();
    await for (var t in tokens) buf.write(t);
    final raw = buf.toString();

    final codeBlock = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```', dotAll: true);
    String? jsonPart;
    if (codeBlock.hasMatch(raw)) {
      jsonPart = codeBlock.firstMatch(raw)!.group(1);
    } else {
      final start = raw.indexOf('[');
      final end = raw.lastIndexOf(']');
      if (start != -1 && end != -1 && end > start) {
        jsonPart = raw.substring(start, end + 1);
      }
    }
    if (jsonPart == null) return [];

    late List<dynamic> decoded;
    try {
      decoded = jsonDecode(jsonPart) as List<dynamic>;
    } on FormatException {
      return [];
    }

    List<Map<String, dynamic>> entries;
    if (decoded.isNotEmpty && decoded.first is Map) {
      entries = decoded.cast<Map<String, dynamic>>();
    } else if (decoded.isNotEmpty &&
        decoded.first is String &&
        decoded.length % 3 == 0) {
      entries = [
        for (var i = 0; i < decoded.length; i += 3)
          {'type': decoded[i], 'x': decoded[i + 1], 'y': decoded[i + 2]},
      ];
    } else {
      return [];
    }

    final specs = <ChartSpec>[];
    for (final m in entries) {
      switch (m['type']) {
        case 'scatter':
          final spots = _extractSpots(rows, m['x'], m['y']);
          if (spots.isNotEmpty) {
            specs.add(
              ChartSpec.scatter(title: '${m['y']} vs ${m['x']}', spots: spots),
            );
          }
          break;
        case 'bar':
          final bars = _extractBars(rows, m['x']);
          if (bars.isNotEmpty) {
            specs.add(ChartSpec.bar(title: m['x'], bars: bars));
          }
          break;
        case 'histogram':
          final hist = _extractHistogram(rows, m['x']);
          if (hist.isNotEmpty) {
            specs.add(ChartSpec.histogram(title: m['x'], spots: hist));
          }
          break;
      }
    }
    return specs;
  }

  /* -------- extract helpers -------- */

  List<FlSpot> _extractSpots(
    List<List<dynamic>> rows,
    String xCol,
    String yCol,
  ) {
    final headers = rows.first.cast<String>();
    final xi = headers.indexOf(xCol);
    final yi = headers.indexOf(yCol);
    if (xi == -1 || yi == -1) return [];

    final data = rows.skip(1);
    return [
      for (var r = 0; r < data.length; r++)
        if (num.tryParse(data.elementAt(r)[xi].toString()) != null &&
            num.tryParse(data.elementAt(r)[yi].toString()) != null)
          FlSpot(
            num.parse(data.elementAt(r)[xi].toString()).toDouble(),
            num.parse(data.elementAt(r)[yi].toString()).toDouble(),
          ),
    ];
  }

  List<BarChartRodData> _extractBars(List<List<dynamic>> rows, String col) {
    final headers = rows.first.cast<String>();
    final idx = headers.indexOf(col);
    if (idx == -1) return [];

    return [
      for (var r = 1; r < rows.length; r++)
        if (num.tryParse(rows[r][idx].toString()) != null)
          BarChartRodData(toY: num.parse(rows[r][idx].toString()).toDouble()),
    ];
  }

  List<FlSpot> _extractHistogram(List<List<dynamic>> rows, String col) {
    final headers = rows.first.cast<String>();
    final idx = headers.indexOf(col);
    if (idx == -1) return [];

    final nums =
        rows
            .skip(1)
            .map((e) => num.tryParse(e[idx].toString()))
            .whereType<num>()
            .map((e) => e.toDouble())
            .toList();
    if (nums.isEmpty) return [];
    nums.sort();
    final binCount = max(5, sqrt(nums.length).round());
    final minVal = nums.first;
    final maxVal = nums.last;
    final step = (maxVal - minVal) / binCount;
    final counts = List<int>.filled(binCount, 0);
    for (final n in nums) {
      final i = min(((n - minVal) / step).floor(), binCount - 1);
      counts[i]++;
    }
    return [
      for (var i = 0; i < binCount; i++)
        FlSpot(minVal + i * step + step / 2, counts[i].toDouble()),
    ];
  }
}

/// ---------------- ChartSpec helper ----------------

class ChartSpec {
  final String title;
  final Widget chart;
  ChartSpec._(this.title, this.chart);

  factory ChartSpec.scatter({
    required String title,
    required List<FlSpot> spots,
  }) {
    return ChartSpec._(
      title,
      ScatterChart(
        ScatterChartData(
          scatterSpots: [for (var s in spots) ScatterSpot(s.x, s.y)],
          titlesData: FlTitlesData(show: true),
        ),
      ),
    );
  }

  factory ChartSpec.bar({
    required String title,
    required List<BarChartRodData> bars,
  }) {
    return ChartSpec._(
      title,
      BarChart(
        BarChartData(
          barGroups: [
            for (var i = 0; i < bars.length; i++)
              BarChartGroupData(x: i, barRods: [bars[i]]),
          ],
        ),
      ),
    );
  }

  factory ChartSpec.histogram({
    required String title,
    required List<FlSpot> spots,
  }) {
    return ChartSpec._(
      title,
      LineChart(LineChartData(lineBarsData: [LineChartBarData(spots: spots)])),
    );
  }
}

/// ---------------- main ----------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationDocumentsDirectory();
  final isar = await Isar.openAsync(
    schemas: [SheetSchema],
    directory: dir.path,
  );

  runApp(
    ProviderScope(
      overrides: [isarProvider.overrideWithValue(isar)],
      child: const MainApp(),
    ),
  );
}

/// ---------------- UI ----------------

class MainApp extends ConsumerWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'PlotPad',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sheets = ref.watch(filteredSheetsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('PlotPad')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search sheets or tags…',
              ),
              onChanged:
                  (v) => ref.read(searchQueryProvider.notifier).state = v,
            ),
          ),
          Expanded(
            child:
                sheets.isEmpty
                    ? const Center(child: Text('No sheets yet'))
                    : ListView.builder(
                      itemCount: sheets.length,
                      itemBuilder: (_, i) {
                        final s = sheets[i];
                        return ListTile(
                          title: Text(s.name),
                          subtitle: Wrap(
                            spacing: 4,
                            children: [
                              for (final t in s.tags)
                                Chip(
                                  label: Text(t),
                                  visualDensity: VisualDensity.compact,
                                ),
                            ],
                          ),
                          onTap:
                              () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => SheetScreen(sheet: s),
                                ),
                              ),
                        );
                      },
                    ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final isar = ref.read(isarProvider);
          await isar.write((isar) {
            final sheet = Sheet(name: 'Untitled Sheet')
              ..id = isar.sheets.autoIncrement();
            isar.sheets.put(sheet);
          });
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

class SheetScreen extends ConsumerStatefulWidget {
  const SheetScreen({super.key, required this.sheet});
  final Sheet sheet;

  @override
  ConsumerState<SheetScreen> createState() => _SheetScreenState();
}

class _SheetScreenState extends ConsumerState<SheetScreen> {
  late TextEditingController _csvCtrl;
  late TextEditingController _tagCtrl;

  @override
  void initState() {
    super.initState();
    _csvCtrl = TextEditingController(text: widget.sheet.csvContent);
    _tagCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _csvCtrl.dispose();
    _tagCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(sheetControllerProvider);
    final sheet = widget.sheet;

    Future<void> promptPassword() async {
      final pwd = await showDialog<String>(
        context: context,
        builder: (ctx) {
          final c = TextEditingController();
          return AlertDialog(
            title: const Text('Enter password'),
            content: TextField(
              controller: c,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, c.text),
                child: const Text('Unlock'),
              ),
            ],
          );
        },
      );
      if (!mounted || pwd == null) return;
      final plain = await controller.unlock(sheet, pwd);
      if (plain == null) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Wrong password')));
        }
      } else {
        setState(() => _csvCtrl.text = plain);
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(sheet.name),
        actions: [
          IconButton(
            tooltip: 'Password',
            icon: Icon(sheet.isEncrypted ? Icons.lock : Icons.lock_open),
            onPressed: () async {
              if (sheet.isEncrypted) {
                await promptPassword();
              } else {
                final pwd = await showDialog<String>(
                  context: context,
                  builder: (ctx) {
                    final c = TextEditingController();
                    return AlertDialog(
                      title: const Text('Set password'),
                      content: TextField(
                        controller: c,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Password',
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel'),
                        ),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(ctx, c.text),
                          child: const Text('Save'),
                        ),
                      ],
                    );
                  },
                );
                if (pwd != null && pwd.isNotEmpty) {
                  await controller.setPassword(sheet, password: pwd);
                  if (mounted) setState(() {});
                }
              }
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _csvCtrl,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'CSV rows',
            ),
            maxLines: 5,
            onChanged: (v) => controller.updateCsv(sheet, v),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 4,
            runSpacing: -4,
            children: [
              for (final tag in sheet.tags)
                Chip(
                  label: Text(tag),
                  onDeleted: () async {
                    await ref.read(isarProvider).write((isar) {
                      sheet.tags.remove(tag);
                      isar.sheets.put(sheet);
                    });
                    setState(() {});
                  },
                ),
              InputChip(
                label: const Text('+'),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder:
                        (_) => AlertDialog(
                          content: TextField(
                            controller: _tagCtrl,
                            autofocus: true,
                            decoration: const InputDecoration(
                              labelText: 'New tag',
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Cancel'),
                            ),
                            ElevatedButton(
                              onPressed: () async {
                                final tag = _tagCtrl.text.trim();
                                if (tag.isNotEmpty) {
                                  await ref.read(isarProvider).write((isar) {
                                    sheet.tags.add(tag);
                                    isar.sheets.put(sheet);
                                  });
                                  _tagCtrl.clear();
                                }
                                if (mounted) Navigator.pop(context);
                                setState(() {});
                              },
                              child: const Text('Add'),
                            ),
                          ],
                        ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            icon: const Icon(Icons.insights),
            label: const Text('Generate Charts'),
            onPressed: () async {
              final specs = await controller.generateCharts(sheet);
              if (!mounted) return;
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => ChartCarousel(specs: specs)),
              );
            },
          ),
        ],
      ),
    );
  }
}

class ChartCarousel extends StatelessWidget {
  const ChartCarousel({super.key, required this.specs});
  final List<ChartSpec> specs;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Charts')),
      body:
          specs.isEmpty
              ? const Center(child: Text('No numeric data found.'))
              : PageView.builder(
                itemCount: specs.length,
                itemBuilder: (_, i) {
                  final spec = specs[i];
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text(
                          spec.title,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 16),
                        Expanded(child: spec.chart),
                      ],
                    ),
                  );
                },
              ),
    );
  }
}
