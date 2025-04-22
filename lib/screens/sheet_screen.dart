import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../models/sheet.dart';
import '../controllers/sheet_controller.dart';
import '../widgets/chart_carousel.dart';

final _log = Logger('SheetScreen');

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
    _log.fine('SheetScreen init for sheet ${widget.sheet.id}');
  }

  @override
  Widget build(BuildContext context) {
    _log.fine('Building SheetScreen');
    final controller = ref.read(sheetControllerProvider);

    return Scaffold(
      appBar: AppBar(title: Text(widget.sheet.name)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _ctrl,
              decoration: const InputDecoration(
                labelText: 'Enter rows, comma‑separated',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
              onChanged: (v) {
                _log.fine('CSV changed: ${v.length} chars');
                controller.updateCsv(widget.sheet, v);
              },
            ),
          ),
          ElevatedButton(
            child: const Text('Generate Charts'),
            onPressed: () async {
              _log.info('Generate Charts tapped');
              final specs = await controller.generateCharts(widget.sheet);
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
