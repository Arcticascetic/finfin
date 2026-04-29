import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'models/transaction.dart';
import 'models/transactions_notifier.dart';
import 'clickwheel.dart';
import 'gui.dart'; // For CategorySelectionScreen

class HomeScreen extends StatefulWidget {
  final List<Transaction> transactions;
  final List<Transaction> allTransactions;
  final String currencySymbol;
  final DateTimeRange? filterRange;
  final List<String> expenseCategories;
  final List<String> incomeCategories;
  final Map<String, double> expenseCategoryLimits;

  // Callbacks
  final Function(double, String, String) onAddTransaction;
  final Function(Transaction) onRemoveTransaction;
  final Function(Transaction, Transaction) onEditTransaction;
  final Function(DateTimeRange?) onUpdateFilter;

  // Lazy Loading Params
  final Set<String> availableMonths;
  final Set<String> loadedMonths;
  final double totalBalance;
  final Function(String) onLoadMonth;
  final Map<String, MonthSummary> monthSummaries;
  final String inputMethod;

  const HomeScreen({
    super.key,
    required this.transactions,
    required this.allTransactions,
    required this.currencySymbol,
    required this.filterRange,
    required this.expenseCategories,
    required this.incomeCategories,
    required this.expenseCategoryLimits,
    required this.onAddTransaction,
    required this.onRemoveTransaction,
    required this.onEditTransaction,
    required this.onUpdateFilter,
    required this.availableMonths,
    required this.loadedMonths,
    required this.totalBalance,
    required this.onLoadMonth,
    required this.monthSummaries,
    required this.inputMethod,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Keep track of expanded years and months so users can minimize to mother transactions.
  final Set<int> _expandedYears = {};
  final Set<String> _expandedMonths = {}; // key: "{year}-{month}"
  // Caching to avoid recomputing grouping on every build for large datasets.

  @override
  void initState() {
    super.initState();
    // Initialize cache and ensure latest month is expanded initially.
    _updateCacheAndEnsureLatestExpanded();
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the list of transactions changes (e.g. lazy load finished, or new item added),
    // we re-evaluate if we need to auto-expand the latest month.
    if (widget.transactions.isNotEmpty &&
        widget.transactions != oldWidget.transactions) {
      _updateCacheAndEnsureLatestExpanded();
    }
  }

  void _updateCacheAndEnsureLatestExpanded() {
    if (widget.transactions.isNotEmpty) {
      // Find the latest transaction and expand its year/month so latest transactions remain visible.
      Transaction? latest;
      if (widget.transactions.isNotEmpty) latest = widget.transactions.first;

      if (latest != null) {
        for (var t in widget.transactions) {
          if (t.date.isAfter(latest!.date)) latest = t;
        }
        final ly = latest!.date.year;
        final lm = latest.date.month;
        _expandedYears.add(ly);
        _expandedMonths.add('$ly-$lm');
      }
    }
  }

  // Show the same transaction menu used before; extracted to instance method so it has access to widget callbacks.
  void _showTransactionMenu(
    BuildContext ctx,
    Offset globalPosition,
    Transaction transaction,
  ) async {
    final RenderBox overlay =
        Overlay.of(ctx).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: ctx,
      position: RelativeRect.fromRect(
        Rect.fromPoints(globalPosition, globalPosition),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(value: 'edit', child: Text('Edit')),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );

    if (selected == 'delete') {
      final confirm = await showDialog<bool>(
        context: ctx,
        builder: (dctx) => AlertDialog(
          title: const Text('Delete Transaction?'),
          content: const Text(
            'Are you sure you want to delete this transaction?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(true),
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
      if (confirm == true) widget.onRemoveTransaction(transaction);
    } else if (selected == 'edit') {
      final bool useKeyboard = widget.inputMethod == 'keyboard';
      if (useKeyboard) {
        final edited = await Navigator.of(ctx).push<Transaction>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (rctx) => TransactionEditorScreen(
              initial: transaction,
              expenseCategories: widget.expenseCategories,
              incomeCategories: widget.incomeCategories,
            ),
          ),
        );
        if (edited != null) {
          widget.onEditTransaction(transaction, edited);
          if (ctx.mounted) {
            ScaffoldMessenger.of(ctx).showSnackBar(
              SnackBar(
                content: Text(
                  'Transaction updated: ${widget.currencySymbol}${edited.amount.toStringAsFixed(2)}',
                ),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        }
      } else {
        final amount = await Navigator.of(ctx).push<double>(
          MaterialPageRoute(
            builder: (rctx) => ClickwheelInputScreen(title: 'Edit Amount'),
          ),
        );
        if (amount != null) {
          final updated = Transaction(
            amount: amount,
            type: transaction.type,
            category: transaction.category,
            date: transaction.date,
          );
          widget.onEditTransaction(transaction, updated);
          if (ctx.mounted) {
            ScaffoldMessenger.of(ctx).showSnackBar(
              SnackBar(
                content: Text(
                  'Transaction updated: ${widget.currencySymbol}${updated.amount.toStringAsFixed(2)}',
                ),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 1. Use the pre-calculated total balance from the widget
    double totalBalance = widget.totalBalance;

    // 2. Build structure from AVAILABLE months (not just loaded ones)
    final available = widget.availableMonths;
    final Map<int, Set<int>> yearStructure = {};
    for (var ym in available) {
      if (ym.length != 6) continue;
      final y = int.parse(ym.substring(0, 4));
      final m = int.parse(ym.substring(4, 6));
      yearStructure.putIfAbsent(y, () => {}).add(m);
    }

    // Sort years descending
    final years = yearStructure.keys.toList()..sort((a, b) => b.compareTo(a));

    return Column(
      children: [
        // --- Total Balance Card ---
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Total Balance:',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '${widget.currencySymbol}${totalBalance.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: totalBalance >= 0
                          ? Colors.green[700]
                          : Colors.red[700],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // --- Grouped Transaction List (Years -> Months -> Transactions) ---
        Expanded(
          child: years.isEmpty
              ? const Center(
                  child: Text(
                    'No transactions in this period.\nAdd some or change the filter.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  itemCount: years.length,
                  itemBuilder: (context, yi) {
                    final year = years[yi];
                    final monthsSet = yearStructure[year]!;
                    final months = monthsSet.toList()
                      ..sort((a, b) => b.compareTo(a));

                    final yearExpanded = _expandedYears.contains(year);

                    // We can't easily calculate year total without loading all months.
                    // UI decision: Show nothing or "..." if not fully loaded.
                    // For simplicity, we just show "History" or similar if needed,
                    // but here we leave subtitle blank or partial.

                    return Card(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: ExpansionTile(
                        key: ValueKey('year-$year'),
                        initiallyExpanded: yearExpanded,
                        title: Text(
                          '$year',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                        // Removed Year Total since it's lazy loaded
                        onExpansionChanged: (open) => setState(() {
                          if (open) {
                            _expandedYears.add(year);
                          } else {
                            _expandedYears.remove(year);
                          }
                        }),
                        children: months.map((month) {
                          final monthKey =
                              '$year-$month'; // e.g. 2023-5 (not padded)
                          // Construct YYYYMM for internal usage
                          final yyyyMM =
                              '$year${month.toString().padLeft(2, '0')}';

                          final isLoaded = widget.loadedMonths.contains(yyyyMM);

                          // Get loaded transactions for this month ONLY if loaded
                          final monthTxns = isLoaded
                              ? widget.transactions
                                    .where(
                                      (t) =>
                                          t.date.year == year &&
                                          t.date.month == month,
                                    )
                                    .toList()
                              : <Transaction>[];

                          if (monthTxns.isNotEmpty) {
                            monthTxns.sort(
                              (a, b) => a.date.compareTo(b.date),
                            ); // Ensure sorted
                          }

                          // Month totals
                          double monthTotal = 0;
                          double monthIncome = 0;
                          double monthExpense = 0;

                          final summary = widget.monthSummaries[yyyyMM];

                          if (summary != null) {
                            monthTotal = summary.net;
                            monthIncome = summary.income;
                            monthExpense = summary.expense;
                          } else if (isLoaded) {
                            for (var t in monthTxns) {
                              if (t.type == 'income') {
                                monthIncome += t.amount;
                                monthTotal += t.amount;
                              } else {
                                monthExpense += t.amount;
                                monthTotal -= t.amount;
                              }
                            }
                          }

                          final monthExpanded = _expandedMonths.contains(
                            monthKey,
                          );
                          final monthName = DateFormat(
                            'MMMM',
                          ).format(DateTime(year, month));

                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8.0,
                            ),
                            child: ExpansionTile(
                              key: ValueKey('month-$monthKey'),
                              title: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    monthName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (isLoaded)
                                    Text(
                                      '${monthTxns.length} items',
                                      style: const TextStyle(
                                        color: Colors.grey,
                                      ),
                                    ),
                                ],
                              ),
                              subtitle: (isLoaded || summary != null)
                                  ? Row(
                                      children: [
                                        Text(
                                          'In: +${widget.currencySymbol}${monthIncome.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            color: Colors.green,
                                            fontSize: 12,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          'Out: -${widget.currencySymbol}${monthExpense.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            color: Colors.red,
                                            fontSize: 12,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          'Net: ${widget.currencySymbol}${monthTotal.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    )
                                  : const Text(
                                      'Tap to load...',
                                      style: TextStyle(
                                        fontStyle: FontStyle.italic,
                                        color: Colors.blue,
                                      ),
                                    ),
                              initiallyExpanded: monthExpanded,
                              onExpansionChanged: (open) {
                                setState(() {
                                  if (open) {
                                    _expandedMonths.add(monthKey);
                                    if (!isLoaded) {
                                      // Lazy Load
                                      widget.onLoadMonth(yyyyMM);
                                    }
                                  } else {
                                    _expandedMonths.remove(monthKey);
                                  }
                                });
                              },
                              children: isLoaded
                                  ? monthTxns.reversed.map((transaction) {
                                      final sign = transaction.type == 'income'
                                          ? '+'
                                          : '-';
                                      final color = transaction.type == 'income'
                                          ? Colors.green
                                          : Colors.red;

                                      return Dismissible(
                                        key: ValueKey(
                                          transaction.date.toIso8601String() +
                                              transaction.amount.toString(),
                                        ),
                                        direction: DismissDirection.horizontal,
                                        background: Container(
                                          color: Colors.redAccent,
                                          alignment: Alignment.centerLeft,
                                          padding: const EdgeInsets.only(
                                            left: 20,
                                          ),
                                          child: const Icon(
                                            Icons.delete,
                                            color: Colors.white,
                                          ),
                                        ),
                                        secondaryBackground: Container(
                                          color: Colors.redAccent,
                                          alignment: Alignment.centerRight,
                                          padding: const EdgeInsets.only(
                                            right: 20,
                                          ),
                                          child: const Icon(
                                            Icons.delete,
                                            color: Colors.white,
                                          ),
                                        ),
                                        onDismissed: (_) => widget
                                            .onRemoveTransaction(transaction),
                                        child: Card(
                                          elevation: 0,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.surfaceContainer,
                                          margin: const EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 4,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              16,
                                            ),
                                          ),
                                          child: ListTile(
                                            onLongPress: () =>
                                                _showTransactionMenu(
                                                  context,
                                                  Offset.zero,
                                                  transaction,
                                                ),
                                            leading: Container(
                                              padding: const EdgeInsets.all(12),
                                              decoration: BoxDecoration(
                                                color: color.withOpacity(0.1),
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                              child: Icon(
                                                transaction.type == 'income'
                                                    ? Icons.arrow_downward
                                                    : Icons.arrow_upward,
                                                color: color,
                                              ),
                                            ),
                                            title: Text(
                                              transaction.category,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            subtitle: Text(
                                              DateFormat(
                                                'MMM d, y',
                                              ).format(transaction.date),
                                              style: TextStyle(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                              ),
                                            ),
                                            trailing: Text(
                                              '$sign${widget.currencySymbol}${transaction.amount.toStringAsFixed(2)}',
                                              style: TextStyle(
                                                color: color,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 16,
                                                fontFamily: 'Outfit',
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    }).toList()
                                  : const [
                                      Padding(
                                        padding: EdgeInsets.all(16.0),
                                        child: Center(
                                          child: Text(
                                            "Expand to load transactions",
                                          ),
                                        ),
                                      ),
                                    ],
                            ),
                          );
                        }).toList(),
                      ),
                    );
                  },
                ),
        ),

        // --- Add Buttons ---
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (ctx) => CategorySelectionScreen(
                          type: 'income',
                          categories: widget.incomeCategories,
                          onConfirmTransaction: widget.onAddTransaction,
                          inputMethod: widget.inputMethod,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Add Income'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    backgroundColor: Colors.green.shade100,
                    foregroundColor: Colors.green.shade800,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (ctx) => CategorySelectionScreen(
                          type: 'expense',
                          categories: widget.expenseCategories,
                          onConfirmTransaction: widget.onAddTransaction,
                          inputMethod: widget.inputMethod,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.remove),
                  label: const Text('Add Expense'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    backgroundColor: Colors.red.shade100,
                    foregroundColor: Colors.red.shade800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// --- Transaction Editor (Full editor used on Desktop) ---
class TransactionEditorScreen extends StatefulWidget {
  final Transaction initial;
  final List<String> expenseCategories;
  final List<String> incomeCategories;

  const TransactionEditorScreen({
    super.key,
    required this.initial,
    required this.expenseCategories,
    required this.incomeCategories,
  });

  @override
  State<TransactionEditorScreen> createState() =>
      _TransactionEditorScreenState();
}

class _TransactionEditorScreenState extends State<TransactionEditorScreen> {
  late TextEditingController _amountController;
  late String _type; // 'income' or 'expense'
  late String _category;

  @override
  void initState() {
    super.initState();
    _amountController = TextEditingController(
      text: widget.initial.amount.toStringAsFixed(2),
    );
    _type = widget.initial.type;
    // Initialize category to the initial transaction's category if present,
    // otherwise fall back to the first available category or empty string.
    final initialList = _type == 'expense'
        ? widget.expenseCategories
        : widget.incomeCategories;
    if (initialList.contains(widget.initial.category)) {
      _category = widget.initial.category;
    } else if (initialList.isNotEmpty) {
      _category = initialList.first;
    } else {
      _category = '';
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categories = _type == 'expense'
        ? widget.expenseCategories
        : widget.incomeCategories;

    bool hasCategories = categories.isNotEmpty;

    bool canSave() {
      final text = _amountController.text.trim();
      final value = double.tryParse(text);
      return hasCategories &&
          value != null &&
          value > 0 &&
          _category.isNotEmpty;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Transaction'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            TextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: false,
              ),
              decoration: const InputDecoration(
                labelText: 'Amount',
                border: OutlineInputBorder(),
                prefixText: '',
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(
                labelText: 'Type',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'income', child: Text('Income')),
                DropdownMenuItem(value: 'expense', child: Text('Expense')),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  _type = v;
                  // If the current category isn't in the new list, pick the first available
                  final list = _type == 'expense'
                      ? widget.expenseCategories
                      : widget.incomeCategories;
                  if (!list.contains(_category) && list.isNotEmpty) {
                    _category = list.first;
                  } else if (list.isEmpty) {
                    _category = '';
                  }
                });
              },
            ),
            const SizedBox(height: 16),
            // Category selector: show ChoiceChips so the selected category is visually highlighted.
            if (hasCategories) ...[
              const Text(
                'Category',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: categories.map((c) {
                  final selected = c == _category;
                  return ChoiceChip(
                    label: Text(c),
                    selected: selected,
                    onSelected: (sel) {
                      if (sel) setState(() => _category = c);
                    },
                    selectedColor: Theme.of(
                      context,
                    ).colorScheme.primary.withAlpha((0.2 * 255).round()),
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    side: selected
                        ? BorderSide(
                            color: Theme.of(context).colorScheme.primary,
                            width: 1.5,
                          )
                        : null,
                  );
                }).toList(),
              ),
            ] else ...[
              // When there are no categories available for the chosen type, show guidance.
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Theme.of(
                    context,
                  ).colorScheme.error.withAlpha((0.08 * 255).round()),
                ),
                child: Text(
                  'No categories available for "$_type". Add categories in Settings before saving.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pop<Transaction?>(null);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey.shade300,
                      foregroundColor: Colors.black,
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: canSave()
                        ? () {
                            final text = _amountController.text.trim();
                            final value = double.tryParse(text);
                            if (value == null || value <= 0) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Enter a valid amount greater than 0',
                                  ),
                                ),
                              );
                              return;
                            }
                            final updated = Transaction(
                              amount: value,
                              type: _type,
                              category: _category,
                              date: widget.initial.date,
                            );
                            Navigator.of(context).pop<Transaction>(updated);
                          }
                        : null,
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}