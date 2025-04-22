import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../models/sheet.dart';
import '../providers.dart';
import 'sheet_screen.dart';

final _log = Logger('HomeScreen');

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    _log.fine('Building HomeScreen');
    final sheetsAsync = ref.watch(sheetListProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('PlotPad')),
      body: sheetsAsync.when(
        data:
            (sheets) => ListView(
              children: [
                for (final s in sheets)
                  ListTile(
                    title: Text(s.name),
                    onTap: () {
                      _log.info('Tapped sheet ${s.id}/${s.name}');
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SheetScreen(sheet: s),
                        ),
                      );
                    },
                  ),
              ],
            ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) {
          _log.severe('Error loading sheets: $e');
          return Center(child: Text('Error: $e'));
        },
      ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.add),
        onPressed: () {
          _log.info('Creating new sheet');
          final isar = ref.read(isarProvider);
          final sheet = Sheet(name: 'New Sheet');
          isar.write((isar) => isar.sheets.put(sheet));
        },
      ),
    );
  }
}
