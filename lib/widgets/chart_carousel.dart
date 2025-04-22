import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../controllers/sheet_controller.dart';

class ChartCarousel extends StatelessWidget {
  final List<ChartSpec> specs;
  const ChartCarousel({super.key, required this.specs});

  @override
  Widget build(BuildContext context) {
    if (specs.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Charts')),
        body: const Center(child: Text('No numeric columns found.')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Charts')),
      body: PageView.builder(
        itemCount: specs.length,
        itemBuilder: (context, i) {
          final spec = specs[i];
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(spec.title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                Expanded(
                  child: LineChart(
                    LineChartData(
                      lineBarsData: [LineChartBarData(spots: spec.spots)],
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
