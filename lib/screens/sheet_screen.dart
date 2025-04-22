import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/sheet.dart';
import '../controllers/sheet_controller.dart';
import '../widgets/chart_carousel.dart';

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
  Widget build(BuildContext context) {
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
              onChanged: (v) => controller.updateCsv(widget.sheet, v),
            ),
          ),
          ElevatedButton(
            child: const Text('Generate Charts'),
            onPressed: () async {
              final specs = await controller.generateCharts(widget.sheet);
              if (!mounted) return;
              if (context.mounted) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChartCarousel(specs: specs),
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}
