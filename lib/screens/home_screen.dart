import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/sheet.dart';
import '../providers.dart';
import 'sheet_screen.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                    onTap:
                        () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => SheetScreen(sheet: s),
                          ),
                        ),
                  ),
              ],
            ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.add),
        onPressed: () async {
          final isar = ref.read(isarProvider);
          final sheet = Sheet(name: 'New Sheet');
          // Use synchronous write so we don't spawn an isolate
          isar.write((isar) {
            isar.sheets.put(sheet);
          });
        },
      ),
    );
  }
}
