import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:csv/csv.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:isar/isar.dart';
import 'package:logging/logging.dart';

import '../models/sheet.dart';
import '../providers.dart';

final _log = Logger('SheetController');

class ChartSpec {
  final String title;
  final List<FlSpot> spots;
  ChartSpec(this.title, this.spots);
}

final sheetControllerProvider = Provider.autoDispose<SheetController>((ref) {
  final isar = ref.read(isarProvider);
  return SheetController(isar);
});

class SheetController {
  final Isar isar;
  SheetController(this.isar);

  Future<void> updateCsv(Sheet sheet, String csv) async {
    _log.info(
      'updateCsv › sheet=${sheet.id}/${sheet.name} length=${csv.length}',
    );
    sheet.csvContent = csv;
    isar.write((isar) {
      isar.sheets.put(sheet);
      _log.fine('Persisted csvContent for sheet ${sheet.id}');
    });
  }

  Future<List<ChartSpec>> generateCharts(Sheet sheet) async {
    // 1) log what we actually received
    _log.fine('Raw CSV: ${sheet.csvContent}');

    // 2) turn every literal backslash-n into a real newline
    final normalized = sheet.csvContent.replaceAll(r'\n', '\n');
    _log.fine('Normalized CSV: $normalized');

    // 3) parse
    final rows = const CsvToListConverter(eol: '\n').convert(normalized);
    _log.fine('Parsed ${rows.length} rows: $rows');

    if (rows.length < 2) {
      _log.warning('Not enough rows (need ≥2)');
      return [];
    }

    final headers = rows.first.cast<String>();
    final data = rows.sublist(1);

    final specs = <ChartSpec>[];
    for (var col = 0; col < headers.length; col++) {
      final maybeNums =
          data.map((r) => num.tryParse(r[col].toString())).toList();
      if (maybeNums.every((n) => n != null)) {
        final spots = <FlSpot>[];
        for (var i = 0; i < maybeNums.length; i++) {
          spots.add(FlSpot(i.toDouble(), maybeNums[i]!.toDouble()));
        }
        specs.add(ChartSpec(headers[col], spots));
      }
    }

    return specs;
  }
}
