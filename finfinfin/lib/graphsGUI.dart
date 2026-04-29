import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

import 'models/transaction.dart';

/// A screen that displays visual analytics of the transactions.
///
/// Features:
/// - Pie chart for expense breakdown.
/// - Line chart for balance history.
/// - Duration selectors (Last 7 days, Last Month, Custom, etc).
class ChartScreen extends StatefulWidget {
  final List<Transaction> transactions; // provided (may be filtered)
  final List<Transaction>?
  allTransactions; // optional full list for re-filtering
  final String currencySymbol;
  final Function(String) onLoadMonth;
  final DateTimeRange? filterRange;
  final Function(DateTimeRange?) onUpdateFilter;

  const ChartScreen({
    super.key,
    required this.transactions,
    required this.currencySymbol,
    required this.onLoadMonth,
    required this.filterRange,
    required this.onUpdateFilter,
    this.allTransactions,
  });

  @override
  State<ChartScreen> createState() => _ChartScreenState();
}

class _ChartScreenState extends State<ChartScreen> {
  String _groupBy = 'Day'; // 'Day', 'Month', 'Year'

  @override
  void initState() {
    super.initState();
  }

  // Helper helpers from main app
  DateTimeRange? getThisMonthRange() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, 1);
    final end = DateTime(
      now.year,
      now.month + 1,
      0,
      23,
      59,
      59,
    ); // Last day of month
    return DateTimeRange(start: start, end: end);
  }

  DateTimeRange? getLastMonthRange() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month - 1, 1);
    final end = DateTime(now.year, now.month, 0, 23, 59, 59);
    return DateTimeRange(start: start, end: end);
  }

  DateTimeRange getLast90DaysRange() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 23, 59, 59);
    final start = DateTime(now.year, now.month, now.day - 90);
    return DateTimeRange(start: start, end: today);
  }

  DateTimeRange getLast120DaysRange() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 23, 59, 59);
    final start = DateTime(now.year, now.month, now.day - 120);
    return DateTimeRange(start: start, end: today);
  }

  DateTimeRange getPastYearRange() {
    final now = DateTime.now();
    final end = DateTime(now.year, now.month, now.day, 23, 59, 59);
    final start = DateTime(now.year, now.month, now.day - 365);
    return DateTimeRange(start: start, end: end);
  }

  String get _filterText {
    if (widget.filterRange == null) return 'All Time';
    final start = DateFormat('MMM d, y').format(widget.filterRange!.start);
    final end = DateFormat('MMM d, y').format(widget.filterRange!.end);
    return '$start - $end';
  }

  Future<void> _pickDateRange(BuildContext context) async {
    final source = widget.allTransactions ?? widget.transactions;
    final firstDate = source.isNotEmpty
        ? source.first.date.subtract(const Duration(days: 30))
        : DateTime.now().subtract(const Duration(days: 365));

    final DateTimeRange? newRange = await showDateRangePicker(
      context: context,
      firstDate: firstDate,
      lastDate: DateTime.now().add(const Duration(days: 30)),
      initialDateRange: widget.filterRange,
    );
    widget.onUpdateFilter(newRange);
  }

  // Helper to generate data for the wealth line chart
  List<FlSpot> _getWealthData(List<Transaction> transactions) {
    final List<FlSpot> data = [];
    double runningTotal = 0.0;

    data.add(const FlSpot(0, 0));

    for (int i = 0; i < transactions.length; i++) {
      final transaction = transactions[i];
      if (transaction.type == 'income') {
        runningTotal += transaction.amount;
      } else {
        runningTotal -= transaction.amount;
      }
      data.add(FlSpot(i.toDouble() + 1, runningTotal));
    }
    return data;
  }

  // Helper to calculate total expenses by category
  Map<String, double> getExpenseCategoryTotals(List<Transaction> txns) {
    final Map<String, double> totals = {};
    for (var txn in txns.where((t) => t.type == 'expense')) {
      totals.update(
        txn.category,
        (value) => value + txn.amount,
        ifAbsent: () => txn.amount,
      );
    }
    return totals;
  }

  @override
  Widget build(BuildContext context) {
    // Use filtered transactions directly
    final txs = widget.transactions;

    if (txs.isEmpty) {
      // Show transient message
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Prevent stacking snackbars
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No data for the selected duration.'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      });
    }

    // --- Prepare Dropdown Items ---
    final List<DropdownMenuItem<DateTimeRange?>> dropdownItems = [
      const DropdownMenuItem(value: null, child: Text('All Time')),
      DropdownMenuItem(
        value: getThisMonthRange(),
        child: const Text('This Month'),
      ),
      DropdownMenuItem(
        value: getLastMonthRange(),
        child: const Text('Last Month'),
      ),
      DropdownMenuItem(
        value: getLast90DaysRange(),
        child: const Text('Last 90 Days'),
      ),
      DropdownMenuItem(
        value: getLast120DaysRange(),
        child: const Text('Last 120 Days'),
      ),
      DropdownMenuItem(
        value: getPastYearRange(),
        child: const Text('Past Year'),
      ),
    ];

    // Ensure the current filter value exists in items
    bool valueExists = false;
    if (widget.filterRange == null) {
      valueExists = true; // matches 'All Time' (null)
    } else {
      for (var item in dropdownItems) {
        if (item.value == widget.filterRange) {
          valueExists = true;
          break;
        }
      }
    }

    if (!valueExists) {
      dropdownItems.add(
        DropdownMenuItem(
          value: widget.filterRange,
          child: const Text('Custom'),
        ),
      );
    }

    final double totalIncome = txs
        .where((t) => t.type == 'income')
        .fold(0.0, (sum, t) => sum + t.amount);
    final double totalExpense = txs
        .where((t) => t.type == 'expense')
        .fold(0.0, (sum, t) => sum + t.amount);
    final wealthData = _getWealthData(txs);
    // Add checks for empty lists before reduce
    final maxY = wealthData.isEmpty
        ? 0
        : wealthData.map((e) => e.y).reduce((a, b) => a > b ? a : b);
    final minY = wealthData.isEmpty
        ? 0
        : wealthData.map((e) => e.y).reduce((a, b) => a < b ? a : b);
    final totalMaxY = [
      totalIncome,
      totalExpense,
    ].reduce((a, b) => a > b ? a : b);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Duration selector
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Showing Data For:',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              DropdownButton<DateTimeRange?>(
                value: widget.filterRange,
                onChanged: (DateTimeRange? newRange) =>
                    widget.onUpdateFilter(newRange),
                items: dropdownItems,
              ),
              TextButton.icon(
                icon: const Icon(Icons.calendar_today, size: 18),
                label: Text(
                  widget.filterRange == null ? 'Custom...' : _filterText,
                ),
                onPressed: () => _pickDateRange(context),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // --- Stacked Bar Chart: Expenses by Category over Time ---
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Expenses by Category',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              DropdownButton<String>(
                value: _groupBy,
                items: const [
                  DropdownMenuItem(value: 'Day', child: Text('Daily')),
                  DropdownMenuItem(value: 'Week', child: Text('Weekly')),
                  DropdownMenuItem(value: 'Month', child: Text('Monthly')),
                  DropdownMenuItem(value: 'Year', child: Text('Yearly')),
                ],
                onChanged: (val) {
                  if (val != null) setState(() => _groupBy = val);
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildStackedBarChart(context, txs, widget.currencySymbol),
          const SizedBox(height: 32),

          // --- Line Chart: Wealth Over Time ---
          Text(
            'Wealth Over Time',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          _buildLineChart(
            context,
            wealthData,
            widget.currencySymbol,
            minY.toDouble(),
            maxY.toDouble(),
          ),
          const SizedBox(height: 32),

          // --- Bar Chart: Total Income vs Expense ---
          Text(
            'Total Income vs. Expense',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          _buildBarChart(
            context,
            totalIncome,
            totalExpense,
            widget.currencySymbol,
            totalMaxY,
          ),
        ],
      ),
    );
  }

  Widget _buildStackedBarChart(
    BuildContext context,
    List<Transaction> transactions,
    String currencySymbol,
  ) {
    // Filter for expenses only
    final expenses = transactions.where((t) => t.type == 'expense').toList();
    if (expenses.isEmpty) {
      return const SizedBox(
        height: 300,
        child: Center(child: Text('No expenses to display.')),
      );
    }

    // Group by Day -> Category -> Amount
    final Map<int, Map<String, double>> dailyData = {};
    final Set<String> categories = {};

    for (var t in expenses) {
      int key;
      if (_groupBy == 'Month') {
        key = (t.date.year * 12) + t.date.month - 1;
      } else if (_groupBy == 'Year') {
        key = t.date.year;
      } else if (_groupBy == 'Week') {
        // Find Monday of the week
        final monday = t.date.subtract(Duration(days: t.date.weekday - 1));
        final normalizedMonday = DateTime(
          monday.year,
          monday.month,
          monday.day,
        );
        key = normalizedMonday.difference(DateTime(1970)).inDays;
      } else {
        key = t.date.difference(DateTime(1970)).inDays;
      }

      dailyData.putIfAbsent(key, () => {});
      dailyData[key]!.update(
        t.category,
        (v) => v + t.amount,
        ifAbsent: () => t.amount,
      );
      categories.add(t.category);
    }

    // Sort days
    final sortedDays = dailyData.keys.toList()..sort();

    // Assign colors to categories
    final List<Color> palette = [
      Colors.blue,
      Colors.red,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.amber,
      Colors.indigo,
      Colors.pink,
      Colors.cyan,
    ];
    final Map<String, Color> categoryColors = {};
    int colorIndex = 0;
    for (var cat in categories) {
      categoryColors[cat] = palette[colorIndex % palette.length];
      colorIndex++;
    }

    // Build BarGroups
    final List<BarChartGroupData> barGroups = [];
    double overallMaxY = 0;

    for (int i = 0; i < sortedDays.length; i++) {
      final day = sortedDays[i];
      final dayData = dailyData[day]!;
      double total = 0;
      final List<BarChartRodStackItem> stackItems = [];

      dayData.forEach((cat, amount) {
        if (amount > 0) {
          stackItems.add(
            BarChartRodStackItem(total, total + amount, categoryColors[cat]!),
          );
          total += amount;
        }
      });

      if (total > overallMaxY) overallMaxY = total;

      barGroups.add(
        BarChartGroupData(
          x: day,
          barRods: [
            BarChartRodData(
              toY: total,
              rodStackItems: stackItems,
              width: 16,
              borderRadius: BorderRadius.circular(4),
              color: Colors.transparent, // Color is controlled by stack items
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Legend
        Wrap(
          spacing: 8,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: categoryColors.entries.map((e) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 12, height: 12, color: e.value),
                const SizedBox(width: 4),
                Text(e.key, style: const TextStyle(fontSize: 12)),
              ],
            );
          }).toList(),
        ),
        const SizedBox(height: 16),
        Container(
          height: 300,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: Theme.of(context).colorScheme.surfaceContainerHighest
                .withAlpha((0.3 * 255).round()),
          ),
          child: BarChart(
            BarChartData(
              alignment: BarChartAlignment.spaceAround,
              gridData: const FlGridData(show: true),
              borderData: FlBorderData(show: false),
              maxY: overallMaxY * 1.1,
              titlesData: FlTitlesData(
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 40,
                    getTitlesWidget: (value, meta) => SideTitleWidget(
                      meta: meta,
                      child: Text(
                        '$currencySymbol${value.toStringAsFixed(0)}',
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    getTitlesWidget: (value, meta) {
                      String text;
                      if (_groupBy == 'Month') {
                        final year = value ~/ 12;
                        final month = (value % 12).toInt() + 1;
                        text = DateFormat(
                          'MMM yy',
                        ).format(DateTime(year, month));
                      } else if (_groupBy == 'Year') {
                        text = value.toInt().toString();
                      } else {
                        // Days or Weeks are both "days since epoch" here
                        final date = DateTime(
                          1970,
                        ).add(Duration(days: value.toInt()));
                        text = DateFormat('MM/dd').format(date);
                      }

                      return SideTitleWidget(
                        meta: meta,
                        child: Text(text, style: const TextStyle(fontSize: 10)),
                      );
                    },
                  ),
                ),
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
              ),
              barGroups: barGroups,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLineChart(
    BuildContext context,
    List<FlSpot> wealthData,
    String currencySymbol,
    double minY,
    double maxY,
  ) {
    return Container(
      height: 300,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withAlpha((0.3 * 255).round()),
      ),
      child: LineChart(
        LineChartData(
          gridData: const FlGridData(show: true),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                getTitlesWidget: (value, meta) => SideTitleWidget(
                  // axisSide: meta.axisSide, // <--- FIX: REMOVED THIS LINE
                  meta: meta,
                  child: Text(
                    '$currencySymbol${value.toStringAsFixed(0)}',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      fontFamily: 'Outfit',
                    ),
                  ),
                ),
              ),
            ),
            bottomTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
          ),
          borderData: FlBorderData(
            show: true,
            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.outline.withAlpha((0.5 * 255).round()),
            ),
          ),
          minY: minY < 0 ? minY * 1.1 : 0,
          maxY: (maxY == 0 && minY == 0)
              ? 100
              : maxY * 1.1, // Handle case where max is 0
          lineBarsData: [
            LineChartBarData(
              spots: wealthData.isEmpty
                  ? [const FlSpot(0, 0)]
                  : wealthData, // Handle empty data
              isCurved: true,
              color: Theme.of(context).colorScheme.primary,
              barWidth: 4,
              isStrokeCapRound: true,
              belowBarData: BarAreaData(
                show: true,
                color: Theme.of(
                  context,
                ).colorScheme.primary.withAlpha((0.2 * 255).round()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBarChart(
    BuildContext context,
    double totalIncome,
    double totalExpense,
    String currencySymbol,
    double totalMaxY,
  ) {
    return Container(
      height: 300,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withAlpha((0.3 * 255).round()),
      ),
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(
            show: true,
            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.outline.withAlpha((0.5 * 255).round()),
            ),
          ),
          minY: 0,
          maxY: totalMaxY > 0 ? totalMaxY * 1.1 : 100,
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                getTitlesWidget: (value, meta) => SideTitleWidget(
                  meta: meta,
                  child: Text(
                    value.toStringAsFixed(0),
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      fontFamily: 'Outfit',
                    ),
                  ),
                ),
              ),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                getTitlesWidget: (value, meta) {
                  if (value == 0) {
                    return const Text(
                      'Income',
                      style: TextStyle(fontSize: 12, fontFamily: 'Outfit'),
                    );
                  }
                  if (value == 1) {
                    return const Text(
                      'Expense',
                      style: TextStyle(fontSize: 12, fontFamily: 'Outfit'),
                    );
                  }
                  return const Text('');
                },
              ),
            ),
          ),
          barGroups: [
            BarChartGroupData(
              x: 0,
              barRods: [
                BarChartRodData(
                  toY: totalIncome,
                  color: Colors.green[600],
                  width: 40,
                  borderRadius: BorderRadius.circular(4),
                ),
              ],
            ),
            BarChartGroupData(
              x: 1,
              barRods: [
                BarChartRodData(
                  toY: totalExpense,
                  color: Colors.red[600],
                  width: 40,
                  borderRadius: BorderRadius.circular(4),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}