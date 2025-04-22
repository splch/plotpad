import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';
import 'package:fl_chart/fl_chart.dart';

import 'models/sheet.dart';

/// 1) Provide the opened Isar instance
final isarProvider = Provider<Isar>((_) => throw UnimplementedError());

/// 2) Stream all sheets
final sheetListProvider = StreamProvider.autoDispose<List<Sheet>>((ref) {
  final isar = ref.watch(isarProvider);
  return isar.sheets.where().watch(fireImmediately: true);
});

/// 3) Controller + chart spec
class ChartSpec {
  final String title;
  final List<FlSpot> spots;
  ChartSpec(this.title, this.spots);
}

final sheetControllerProvider = Provider.autoDispose<SheetController>((ref) {
  return SheetController(ref.read(isarProvider));
});

class SheetController {
  final Isar _isar;
  SheetController(this._isar);

  Future<void> updateCsv(Sheet sheet, String csv) async {
    sheet.csvContent = csv;
    _isar.write((isar) {
      isar.sheets.put(sheet);
    });
  }

  Future<List<ChartSpec>> generateCharts(Sheet sheet) async {
    final normalized = sheet.csvContent.replaceAll(r'\n', '\n');
    final rows = const CsvToListConverter(eol: '\n').convert(normalized);

    if (rows.length < 2) return [];

    final headers = rows.first.cast<String>();
    final data = rows.sublist(1);

    return [
      for (var c = 0; c < headers.length; c++)
        if (data.every((r) => num.tryParse(r[c].toString()) != null))
          ChartSpec(
            headers[c],
            List.generate(
              data.length,
              (i) => FlSpot(
                i.toDouble(),
                num.parse(data[i][c].toString()).toDouble(),
              ),
            ),
          ),
    ];
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dir = await getApplicationDocumentsDirectory();
  // Isar.open returns synchronously here—no await
  final isar = Isar.open(schemas: [SheetSchema], directory: dir.path);

  runApp(
    ProviderScope(
      overrides: [isarProvider.overrideWithValue(isar)],
      child: const MainApp(),
    ),
  );
}

class MainApp extends ConsumerWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'PlotPad',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sheetsAsync = ref.watch(sheetListProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('PlotPad')),
      body: sheetsAsync.when(
        data:
            (sheets) => ListView.builder(
              itemCount: sheets.length,
              itemBuilder: (_, i) {
                final s = sheets[i];
                return ListTile(
                  title: Text(s.name),
                  onTap:
                      () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SheetScreen(sheet: s),
                        ),
                      ),
                );
              },
            ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          final isar = ref.read(isarProvider);
          isar.write((isar) => isar.sheets.put(Sheet(name: 'New Sheet')));
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

class SheetScreen extends ConsumerStatefulWidget {
  final Sheet sheet;
  const SheetScreen({super.key, required this.sheet});

  @override
  ConsumerState<SheetScreen> createState() => _SheetScreenState();
}

class _SheetScreenState extends ConsumerState<SheetScreen> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.sheet.csvContent);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(sheetControllerProvider);

    return Scaffold(
      appBar: AppBar(title: Text(widget.sheet.name)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _ctrl,
              decoration: const InputDecoration(
                labelText: 'Rows (CSV)',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
              onChanged: (v) => controller.updateCsv(widget.sheet, v),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () async {
                final specs = await controller.generateCharts(widget.sheet);
                if (!context.mounted) return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChartCarousel(specs: specs),
                  ),
                );
              },
              child: const Text('Generate Charts'),
            ),
          ],
        ),
      ),
    );
  }
}

class ChartCarousel extends StatelessWidget {
  final List<ChartSpec> specs;
  const ChartCarousel({super.key, required this.specs});

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
                        Expanded(
                          child: LineChart(
                            LineChartData(
                              lineBarsData: [
                                LineChartBarData(spots: spec.spots),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
    );
  }
}
