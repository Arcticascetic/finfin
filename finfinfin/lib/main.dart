import 'package:flutter/material.dart';
import 'dart:async'; // For Timer
import 'dart:convert'; // For JSON encoding/decoding
import 'package:shared_preferences/shared_preferences.dart'; // For saving data
import 'package:fl_chart/fl_chart.dart'; // For charts
import 'package:intl/intl.dart'; // For date formatting
import 'dart:io' show Platform, File;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

void main() {
  // Ensure the app starts with necessary bindings for date formatting
  Intl.defaultLocale = 'en_US';
  WidgetsFlutterBinding.ensureInitialized();
  // Wrap the app with a top-level MaterialApp to guarantee MaterialLocalizations
  // are available to any widget that may be built during initialization.
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: BudgetApp(),
  ));
}

// --- Global Default Categories (Used only for first run) ---
const List<String> defaultExpenseCategories = [
  'Housing', 'Food', 'Transport', 'Utilities', 'Entertainment',
  'Health', 'Savings', 'Other Expense'
];

const List<String> defaultIncomeCategories = [
  'Salary', 'Investments', 'Gift', 'Rental Income', 'Other Income'
];

// Helper to determine the start and end of the current month
DateTimeRange getThisMonthRange() {
  final now = DateTime.now();
  final firstDay = DateTime(now.year, now.month, 1);
  final lastDay = DateTime(now.year, now.month + 1, 0);
  return DateTimeRange(start: firstDay, end: lastDay);
}

// Helper to determine the start and end of the last month
DateTimeRange getLastMonthRange() {
  final now = DateTime.now();
  final firstDayOfCurrentMonth = DateTime(now.year, now.month, 1);
  final lastDayOfLastMonth = firstDayOfCurrentMonth.subtract(const Duration(days: 1));
  final firstDayOfLastMonth = DateTime(lastDayOfLastMonth.year, lastDayOfLastMonth.month, 1);
  return DateTimeRange(start: firstDayOfLastMonth, end: lastDayOfLastMonth);
}

// --- Main App Widget (Manages Global State: Theme, Currency, and Filter) ---
class BudgetApp extends StatefulWidget {
  const BudgetApp({super.key});

  @override
  State<BudgetApp> createState() => _BudgetAppState();
}

class _BudgetAppState extends State<BudgetApp> {
  // Global App Settings State
  String _currencySymbol = '\$';
  ThemeMode _themeMode = ThemeMode.light;
  DateTimeRange? _filterRange; // Null means 'All Time'

  // Dynamic Category State
  List<String> _expenseCategories = [];
  List<String> _incomeCategories = [];

  // Transaction State
  List<Transaction> _transactions = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettingsAndData();
  }

  // --- Persistence & Initialization ---

  Future<void> _loadSettingsAndData() async {
    final prefs = await SharedPreferences.getInstance();

    // 1. Load Settings
    final savedCurrency = prefs.getString('currencySymbol');
    final isDarkMode = prefs.getBool('isDarkMode') ?? false;

    // 2. Load Categories (use defaults if none saved)
    final expenseStrings = prefs.getStringList('expenseCategories');
    final incomeStrings = prefs.getStringList('incomeCategories');
    
    // 3. Load Transactions
    final transactionStrings = prefs.getStringList('transactions');

    setState(() {
      _currencySymbol = savedCurrency ?? '\$';
      _themeMode = isDarkMode ? ThemeMode.dark : ThemeMode.light;
      
      _expenseCategories = expenseStrings ?? defaultExpenseCategories;
      _incomeCategories = incomeStrings ?? defaultIncomeCategories;

      if (transactionStrings != null) {
        // --- FIX for Problem 1: Handle Corrupted Data ---
        _transactions = transactionStrings.map((jsonString) {
          try {
            // Try to parse the transaction
            final jsonMap = json.decode(jsonString) as Map<String, dynamic>;
            return Transaction.fromJson(jsonMap);
          } catch (e) {
            // If it fails (corrupted data, old format, etc.), log it and skip.
            print('Failed to load transaction: $jsonString. Error: $e');
            return null; // Return null for the bad entry
          }
        }).whereType<Transaction>().toList(); // Filters out all the null (bad) entries
        // --- End of FIX ---
      }
      _isLoading = false;
    });
  }

  Future<void> _saveTransactions() async {
    final prefs = await SharedPreferences.getInstance();
    final transactionStrings = _transactions.map((transaction) {
      final jsonMap = transaction.toJson();
      return json.encode(jsonMap);
    }).toList();
    await prefs.setStringList('transactions', transactionStrings);
  }

  Future<void> _saveCategories() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('expenseCategories', _expenseCategories);
    await prefs.setStringList('incomeCategories', _incomeCategories);
  }

  Future<void> _saveSettings({String? currency, ThemeMode? mode}) async {
    final prefs = await SharedPreferences.getInstance();
    if (currency != null) {
      await prefs.setString('currencySymbol', currency);
    }
    if (mode != null) {
      await prefs.setBool('isDarkMode', mode == ThemeMode.dark);
    }
  }

  // --- App Logic Methods ---

  void _addTransaction(double amount, String type, String category) {
    setState(() {
      _transactions.add(Transaction(
          amount: amount,
          type: type,
          category: category,
          date: DateTime.now()));
      _transactions.sort((a, b) => a.date.compareTo(b.date)); // Keep sorted by date
    });
    _saveTransactions();
  }

  void _removeTransaction(Transaction transactionToRemove) {
    setState(() {
      _transactions.remove(transactionToRemove);
    });
    _saveTransactions();
  }

  /// Replace an existing transaction with an updated one.
  /// This supports editing amount, type, and category.
  void _updateTransaction(Transaction oldTransaction, Transaction newTransaction) {
    final idx = _transactions.indexWhere((t) =>
        t.date == oldTransaction.date &&
        t.type == oldTransaction.type &&
        t.category == oldTransaction.category &&
        t.amount == oldTransaction.amount);
    if (idx != -1) {
      setState(() {
        _transactions[idx] = newTransaction;
      });
      _saveTransactions();
    }
  }

  void _updateThemeMode(ThemeMode newMode) {
    setState(() {
      _themeMode = newMode;
    });
    _saveSettings(mode: newMode);
  }

  void _updateCurrency(String newCurrency) {
    setState(() {
      _currencySymbol = newCurrency;
    });
    _saveSettings(currency: newCurrency);
  }

  void _updateFilterRange(DateTimeRange? newRange) {
    setState(() {
      _filterRange = newRange;
    });
  }

  void _updateCategories(String type, List<String> newCategories) {
    setState(() {
      if (type == 'expense') {
        _expenseCategories = newCategories;
      } else if (type == 'income') {
        _incomeCategories = newCategories;
      }
    });
    // Save the updated list immediately
    _saveCategories();
  }

  // Filtered List Getter
  List<Transaction> get _filteredTransactions {
    if (_filterRange == null) {
      return _transactions;
    }
    // Filter logic: includes transactions from start date up to the end of the end date
    return _transactions.where((t) {
      final isAfterStart = t.date.isAfter(_filterRange!.start.subtract(const Duration(microseconds: 1)));
      final isBeforeEnd = t.date.isBefore(_filterRange!.end.add(const Duration(days: 1)).subtract(const Duration(microseconds: 1)));
      return isAfterStart && isBeforeEnd;
    }).toList();
  }

  // --- Build Method ---
  @override
  Widget build(BuildContext context) {
    
    const Color primaryBlue = Color(0xFF00BCD4);

    return MaterialApp(
      title: 'Clickwheel Budget App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryBlue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryBlue,
          brightness: Brightness.dark,
        ).copyWith(
          background: const Color(0xFF0A192F),
          surface: const Color(0xFF102A43),
          primary: primaryBlue,
        ),
        useMaterial3: true,
      ),
      themeMode: _themeMode,
      home: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Clickwheel Budget'),
            backgroundColor: Theme.of(context).colorScheme.inversePrimary,
            actions: [
              IconButton(
                icon: const Icon(Icons.settings),
                onPressed: () => _showSettings(context),
              ),
            ],
            bottom: const TabBar(
              tabs: [
                const Tab(icon: Icon(Icons.list_alt), text: 'Transactions'),
                const Tab(icon: Icon(Icons.show_chart), text: 'Charts'),
              ],
            ),
          ),
          body: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  children: [
                    // --- Tab 1: Home Screen ---
                    HomeScreen(
                      transactions: _filteredTransactions,
                      allTransactions: _transactions, 
                      currencySymbol: _currencySymbol,
                      filterRange: _filterRange,
                        expenseCategories: _expenseCategories,
                        incomeCategories: _incomeCategories,
                      onAddTransaction: _addTransaction,
                      onRemoveTransaction: _removeTransaction,
                      onEditTransaction: _updateTransaction,
                      onUpdateFilter: _updateFilterRange,
                    ),
                    // --- Tab 2: Chart Screen ---
                    ChartScreen(
                        transactions: _filteredTransactions,
                        currencySymbol: _currencySymbol),
                  ],
                ),
        ),
      ),
    );
  }

  // --- Settings Modal Bottom Sheet ---
  void _showSettings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) {
        return SettingsSheet(
          themeMode: _themeMode,
          currencySymbol: _currencySymbol,
          expenseCategories: _expenseCategories, 
          incomeCategories: _incomeCategories,
          allTransactions: _transactions, // Pass the full list for checking
          onUpdateTheme: _updateThemeMode,
          onUpdateCurrency: _updateCurrency,
          onUpdateCategories: _updateCategories, 
          onImportTransactions: (jsonString) => _importTransactionsFromJsonString(ctx, jsonString),
        );
      },
    );
  }

  /// Import transactions from a JSON string. Accepts either:
  /// - A JSON array of strings (each string is a JSON-encoded transaction map), or
  /// - A JSON array of maps (each is a transaction map).
  /// This replaces any existing transactions (old data is deleted) and persists the new set.
  Future<void> _importTransactionsFromJsonString(BuildContext ctx, String jsonString) async {
    bool dialogShown = false;
    final counts = ValueNotifier<Map<String, int>>({'total': 0, 'processed': 0, 'imported': 0, 'skipped': 0});
    try {
      final decoded = json.decode(jsonString);
      if (decoded is! List) throw const FormatException('Top-level JSON value must be an array');

      counts.value = {...counts.value, 'total': decoded.length};

      // Show a progress dialog that listens to `counts` updates.
      dialogShown = true;
      showDialog<void>(
        context: ctx,
        barrierDismissible: false,
        builder: (dctx) {
          return AlertDialog(
            title: const Text('Importing Transactions'),
            content: ValueListenableBuilder<Map<String, int>>(
              valueListenable: counts,
              builder: (context, value, _) {
                final total = value['total'] ?? 0;
                final processed = value['processed'] ?? 0;
                final imported = value['imported'] ?? 0;
                final skipped = value['skipped'] ?? 0;
                final progress = total > 0 ? processed / total : 0.0;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: 12),
                    Text('Processed: $processed / $total'),
                    Text('Imported: $imported  Skipped: $skipped'),
                  ],
                );
              },
            ),
          );
        },
      );

      final List<String> stringList = [];
      final List<Transaction> parsed = [];

      for (var item in decoded) {
        // process each item and update counts so dialog shows progress
        if (item is String) {
          try {
            final map = json.decode(item) as Map<String, dynamic>;
            parsed.add(Transaction.fromJson(map));
            stringList.add(item);
            counts.value = {
              ...counts.value,
              'processed': (counts.value['processed'] ?? 0) + 1,
              'imported': (counts.value['imported'] ?? 0) + 1,
            };
          } catch (e) {
            counts.value = {
              ...counts.value,
              'processed': (counts.value['processed'] ?? 0) + 1,
              'skipped': (counts.value['skipped'] ?? 0) + 1,
            };
            continue;
          }
        } else if (item is Map) {
          try {
            final map = Map<String, dynamic>.from(item);
            parsed.add(Transaction.fromJson(map));
            stringList.add(json.encode(map));
            counts.value = {
              ...counts.value,
              'processed': (counts.value['processed'] ?? 0) + 1,
              'imported': (counts.value['imported'] ?? 0) + 1,
            };
          } catch (e) {
            counts.value = {
              ...counts.value,
              'processed': (counts.value['processed'] ?? 0) + 1,
              'skipped': (counts.value['skipped'] ?? 0) + 1,
            };
            continue;
          }
        } else {
          counts.value = {
            ...counts.value,
            'processed': (counts.value['processed'] ?? 0) + 1,
            'skipped': (counts.value['skipped'] ?? 0) + 1,
          };
          continue;
        }
        // allow UI to update between iterations for very large lists
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      // Replace existing transactions with the new parsed list
      setState(() {
        _transactions = parsed;
      });
      await _saveTransactions();

      // close the progress dialog
      if (dialogShown && ctx.mounted) Navigator.of(ctx).pop();
      dialogShown = false;

      // Show final result
      final importedCount = counts.value['imported'] ?? parsed.length;
      final skippedCount = counts.value['skipped'] ?? 0;
      if (ctx.mounted) {
        showDialog(
          context: ctx,
          builder: (dctx) => AlertDialog(
            title: const Text('Import Complete'),
            content: Text('Imported $importedCount transactions. Skipped $skippedCount invalid entries.'),
            actions: [TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('OK'))],
          ),
        );
      }
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
          content: Text('Imported $importedCount transactions (skipped $skippedCount).'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      // ensure progress dialog is closed on error
      if (dialogShown && ctx.mounted) Navigator.of(ctx).pop();
      dialogShown = false;
      if (ctx.mounted) {
        showDialog(
          context: ctx,
          builder: (dctx) => AlertDialog(
            title: const Text('Import Failed'),
            content: Text('Failed to parse the provided JSON: $e'),
            actions: [TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('OK'))],
          ),
        );
      }
    } finally {
      counts.dispose();
    }
  }
}

// --- Transaction Data Model ---
class Transaction {
  final double amount;
  final String type; // 'income' or 'expense'
  final String category;
  final DateTime date;

  Transaction(
      {required this.amount,
      required this.type,
      required this.category,
      required this.date});

  Map<String, dynamic> toJson() => {
        'amount': amount,
        'type': type,
        'category': category,
        'date': date.toIso8601String(),
      };

  factory Transaction.fromJson(Map<String, dynamic> json) {
    // Add checks to ensure data integrity
    if (json['amount'] == null ||
        json['type'] == null ||
        json['category'] == null ||
        json['date'] == null) {
      throw const FormatException("Missing required field in transaction JSON");
    }
    
    // Parse date and normalize to local time so display/grouping is consistent.
    final parsedDate = DateTime.parse(json['date'] as String).toLocal();
    return Transaction(
      amount: (json['amount'] as num).toDouble(), // Safer parsing
      type: json['type'] as String,
      category: json['category'] as String,
      date: parsedDate,
    );
  }
}

// --- Category Selection Screen ---
class CategorySelectionScreen extends StatelessWidget {
  final String type; // 'income' or 'expense'
  final List<String> categories;
  final Function(double, String, String) onConfirmTransaction;

  const CategorySelectionScreen(
      {super.key, required this.type, required this.categories, required this.onConfirmTransaction});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${type == 'expense' ? 'Select Expense' : 'Select Income'} Category'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: categories.isEmpty
          ? const Center(child: Text('No categories defined. Add them in Settings.'))
          : GridView.builder(
              padding: const EdgeInsets.all(16.0),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 3,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              itemCount: categories.length,
              itemBuilder: (context, index) {
                final category = categories[index];
                return ElevatedButton(
                  onPressed: () async {
                    // Navigate to ClickwheelInputScreen after selection
                    final amount = await Navigator.of(context).push<double>(
                      MaterialPageRoute(
                        builder: (ctx) => ClickwheelInputScreen(
                          title: 'Enter Amount for $category',
                        ),
                      ),
                    );

                    if (amount != null && amount > 0) {
                      onConfirmTransaction(amount, type, category);
                    }
                    // Pop back to the main screen after input is done
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.surfaceVariant,
                    foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
                    elevation: 4,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(
                    category,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                );
              },
            ),
    );
  }
}

// --- HomeScreen with Year/Month grouping (collapsible mother transactions) ---
class HomeScreen extends StatefulWidget {
  final List<Transaction> transactions;
  final List<Transaction> allTransactions;
  final String currencySymbol;
  final DateTimeRange? filterRange;
  final List<String> expenseCategories;
  final List<String> incomeCategories;
  final Function(double, String, String) onAddTransaction;
  final Function(Transaction) onRemoveTransaction;
  // onEditTransaction: (oldTransaction, newTransaction)
  final Function(Transaction, Transaction) onEditTransaction;
  final Function(DateTimeRange?) onUpdateFilter;

  const HomeScreen({
    super.key,
    required this.transactions,
    required this.allTransactions,
    required this.currencySymbol,
    required this.filterRange,
    required this.expenseCategories,
    required this.incomeCategories,
    required this.onAddTransaction,
    required this.onRemoveTransaction,
    required this.onEditTransaction,
    required this.onUpdateFilter,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Keep track of expanded years and months so users can minimize to mother transactions.
  final Set<int> _expandedYears = {};
  final Set<String> _expandedMonths = {}; // key: "{year}-{month}"
  // Caching to avoid recomputing grouping on every build for large datasets.
  String? _cachedTxKey;
  Map<int, Map<int, List<Transaction>>>? _cachedGrouped;

  @override
  void initState() {
    super.initState();
    // Initialize cache and ensure latest month is expanded initially.
    _updateCacheAndEnsureLatestExpanded();
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If transactions reference changed or content changed, update cache and expand latest.
    final newKey = _computeTxKey(widget.transactions);
    if (newKey != _cachedTxKey) {
      setState(() {
        _updateCacheAndEnsureLatestExpanded();
      });
    }
  }

  String _computeTxKey(List<Transaction> txns) {
    // Simple checksum: length + concatenation of timestamp and amount for each txn.
    // This is intentionally simple and fast; it should change when transactions change.
    final sb = StringBuffer();
    sb.write(txns.length);
    for (var t in txns) {
      sb.write('|${t.date.millisecondsSinceEpoch}:${t.amount}:${t.type}:${t.category}');
    }
    return sb.toString();
  }

  void _updateCacheAndEnsureLatestExpanded() {
    _cachedTxKey = _computeTxKey(widget.transactions);
    _cachedGrouped = _groupByYearMonth(widget.transactions);
    if (widget.transactions.isNotEmpty) {
      // Find the latest transaction and expand its year/month so latest transactions remain visible.
      Transaction latest = widget.transactions.first;
      for (var t in widget.transactions) {
        if (t.date.isAfter(latest.date)) latest = t;
      }
      final ly = latest.date.year;
      final lm = latest.date.month;
      _expandedYears.add(ly);
      _expandedMonths.add('$ly-$lm');
    }
  }

  String get _filterText {
    if (widget.filterRange == null) return 'All Time';
    final start = DateFormat('MMM d, y').format(widget.filterRange!.start);
    final end = DateFormat('MMM d, y').format(widget.filterRange!.end);
    return '$start - $end';
  }

  Future<void> _pickDateRange(BuildContext context) async {
    final DateTimeRange? newRange = await showDateRangePicker(
      context: context,
      firstDate: widget.allTransactions.isNotEmpty
          ? widget.allTransactions.first.date.subtract(const Duration(days: 30))
          : DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 30)),
      initialDateRange: widget.filterRange,
    );
    widget.onUpdateFilter(newRange);
  }

  // Group transactions into a map: year -> month -> list
  Map<int, Map<int, List<Transaction>>> _groupByYearMonth(List<Transaction> txns) {
    final Map<int, Map<int, List<Transaction>>> result = {};
    for (var t in txns) {
      final y = t.date.year;
      final m = t.date.month;
      result.putIfAbsent(y, () => {});
      result[y]!.putIfAbsent(m, () => []);
      result[y]![m]!.add(t);
    }
    // Sort each month list by date ascending
    for (var y in result.keys) {
      for (var m in result[y]!.keys) {
        result[y]![m]!.sort((a, b) => a.date.compareTo(b.date));
      }
    }
    return result;
  }

  // Show the same transaction menu used before; extracted to instance method so it has access to widget callbacks.
  void _showTransactionMenu(BuildContext ctx, Offset globalPosition, Transaction transaction) async {
    final RenderBox overlay = Overlay.of(ctx).context.findRenderObject() as RenderBox;
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
          content: const Text('Are you sure you want to delete this transaction?'),
          actions: [
            TextButton(onPressed: () => Navigator.of(dctx).pop(false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.of(dctx).pop(true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
          ],
        ),
      );
      if (confirm == true) widget.onRemoveTransaction(transaction);
    } else if (selected == 'edit') {
      final bool isDesktop = !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);
      if (isDesktop) {
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
            ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
              content: Text('Transaction updated: ${widget.currencySymbol}${edited.amount.toStringAsFixed(2)}'),
              behavior: SnackBarBehavior.floating,
            ));
          }
        }
      } else {
        final amount = await Navigator.of(ctx).push<double>(
          MaterialPageRoute(builder: (rctx) => ClickwheelInputScreen(title: 'Edit Amount')),
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
            ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
              content: Text('Transaction updated: ${widget.currencySymbol}${updated.amount.toStringAsFixed(2)}'),
              behavior: SnackBarBehavior.floating,
            ));
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final transactions = widget.transactions;

    double totalBalance = transactions.fold(0.0, (sum, item) {
      if (item.type == 'income') return sum + item.amount;
      return sum - item.amount;
    });

  // Use cached grouping when available to improve performance on large lists.
  final grouped = _cachedGrouped ?? _groupByYearMonth(transactions);
    // Sort years descending
    final years = grouped.keys.toList()..sort((a, b) => b.compareTo(a));

    return Column(
      children: [
        // --- Filter Control ---
        Padding(
          padding: const EdgeInsets.only(top: 16.0, left: 16.0, right: 16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Showing Data For:', style: Theme.of(context).textTheme.bodyLarge),
              DropdownButton<DateTimeRange?>(
                value: widget.filterRange,
                onChanged: (DateTimeRange? newRange) => widget.onUpdateFilter(newRange),
                items: [
                  const DropdownMenuItem(value: null, child: Text('All Time')),
                  DropdownMenuItem(value: getThisMonthRange(), child: const Text('This Month')),
                  DropdownMenuItem(value: getLastMonthRange(), child: const Text('Last Month')),
                ],
              ),
              TextButton.icon(
                icon: const Icon(Icons.calendar_today, size: 18),
                label: Text(widget.filterRange == null ? 'Custom...' : _filterText),
                onPressed: () => _pickDateRange(context),
              ),
            ],
          ),
        ),

        // --- Total Balance Card ---
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Card(
            color: Theme.of(context).colorScheme.surfaceVariant,
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Total Balance:', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  Text(
                    '${widget.currencySymbol}${totalBalance.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: totalBalance >= 0 ? Colors.green[700] : Colors.red[700],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // --- Grouped Transaction List (Years -> Months -> Transactions) ---
        Expanded(
          child: transactions.isEmpty
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
                    final monthsMap = grouped[year]!;
                    final months = monthsMap.keys.toList()..sort((a, b) => b.compareTo(a));

                    // Year total
                    double yearTotal = 0;
                    for (var m in months) {
                      for (var t in monthsMap[m]!) {
                        yearTotal += t.type == 'income' ? t.amount : -t.amount;
                      }
                    }

                    final yearExpanded = _expandedYears.contains(year);

                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: ExpansionTile(
                        key: ValueKey('year-$year'),
                        initiallyExpanded: yearExpanded,
                        title: Text('$year', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                        trailing: Text('${widget.currencySymbol}${yearTotal.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                        onExpansionChanged: (open) => setState(() {
                          if (open) _expandedYears.add(year); else _expandedYears.remove(year);
                        }),
                        children: months.map((month) {
                          final monthKey = '$year-$month';
                          final txns = monthsMap[month]!;
                          // Month total
                          double monthTotal = txns.fold(0.0, (s, t) => s + (t.type == 'income' ? t.amount : -t.amount));

                          final monthExpanded = _expandedMonths.contains(monthKey);
                          final monthName = DateFormat('MMMM').format(DateTime(year, month));

                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8.0),
                            child: ExpansionTile(
                              key: ValueKey('month-$monthKey'),
                              title: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('$monthName', style: const TextStyle(fontWeight: FontWeight.w600)),
                                  Text('${txns.length} items', style: const TextStyle(color: Colors.grey)),
                                ],
                              ),
                              subtitle: Text('${widget.currencySymbol}${monthTotal.toStringAsFixed(2)}'),
                              initiallyExpanded: monthExpanded,
                              onExpansionChanged: (open) => setState(() {
                                if (open) _expandedMonths.add(monthKey); else _expandedMonths.remove(monthKey);
                              }),
                              children: txns.reversed.map((transaction) {
                                final sign = transaction.type == 'income' ? '+' : '-';
                                final color = transaction.type == 'income' ? Colors.green : Colors.red;

                                return Dismissible(
                                  key: ValueKey(transaction.date.toIso8601String() + transaction.amount.toString()),
                                  direction: DismissDirection.horizontal,
                                  background: Container(
                                    color: Colors.redAccent,
                                    alignment: Alignment.centerLeft,
                                    padding: const EdgeInsets.only(left: 20),
                                    child: const Icon(Icons.delete, color: Colors.white),
                                  ),
                                  secondaryBackground: Container(
                                    color: Colors.redAccent,
                                    alignment: Alignment.centerRight,
                                    padding: const EdgeInsets.only(right: 20),
                                    child: const Icon(Icons.delete, color: Colors.white),
                                  ),
                                  onDismissed: (_) => widget.onRemoveTransaction(transaction),
                                  child: Card(
                                    margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                    child: GestureDetector(
                                      onLongPressStart: (details) => _showTransactionMenu(context, details.globalPosition, transaction),
                                      onSecondaryTapDown: (details) => _showTransactionMenu(context, details.globalPosition, transaction),
                                      child: ListTile(
                                        leading: Icon(transaction.type == 'income' ? Icons.arrow_circle_up : Icons.arrow_circle_down, color: color),
                                        title: Text(transaction.category, style: const TextStyle(fontWeight: FontWeight.bold)),
                                        subtitle: Text('${transaction.type == 'income' ? 'Income' : 'Expense'} - ${DateFormat('MMM d, hh:mm a').format(transaction.date)}'),
                                        trailing: Text('$sign ${widget.currencySymbol}${transaction.amount.toStringAsFixed(2)}', style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16)),
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
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

// --- ChartScreen with Pie Chart (No changes) ---
class ChartScreen extends StatelessWidget {
  final List<Transaction> transactions;
  final String currencySymbol;
  const ChartScreen({super.key, required this.transactions, required this.currencySymbol});

  // Helper to generate data for the wealth line chart
  List<FlSpot> _getWealthData() {
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
      totals.update(txn.category, (value) => value + txn.amount,
          ifAbsent: () => txn.amount);
    }
    return totals;
  }

  @override
  Widget build(BuildContext context) {
    if (transactions.isEmpty) {
      return const Center(
        child: Text(
          'No data to plot in this period.\nChange the filter or add transactions.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, color: Colors.grey),
        ),
      );
    }

    final double totalIncome = transactions
        .where((t) => t.type == 'income')
        .fold(0.0, (sum, t) => sum + t.amount);
    final double totalExpense = transactions
        .where((t) => t.type == 'expense')
        .fold(0.0, (sum, t) => sum + t.amount);
    final expenseCategoryTotals = getExpenseCategoryTotals(transactions);
    final wealthData = _getWealthData();
    // Add checks for empty lists before reduce
    final maxY = wealthData.isEmpty ? 0 : wealthData.map((e) => e.y).reduce((a, b) => a > b ? a : b);
    final minY = wealthData.isEmpty ? 0 : wealthData.map((e) => e.y).reduce((a, b) => a < b ? a : b);
    final totalMaxY = [totalIncome, totalExpense].reduce((a, b) => a > b ? a : b);
    final totalExpenseAmount = totalExpense;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // --- Pie Chart: Expense Breakdown by Category ---
          Text(
            'Expense Breakdown ($currencySymbol${totalExpenseAmount.toStringAsFixed(2)})',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          _buildExpensePieChart(
              context, expenseCategoryTotals, totalExpenseAmount),
          const SizedBox(height: 32),

          // --- Line Chart: Wealth Over Time ---
          Text(
            'Wealth Over Time',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          _buildLineChart(context, wealthData, currencySymbol, minY.toDouble(), maxY.toDouble()),
          const SizedBox(height: 32),

          // --- Bar Chart: Total Income vs Expense ---
          Text(
            'Total Income vs. Expense',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          _buildBarChart(
              context, totalIncome, totalExpense, currencySymbol, totalMaxY),
        ],
      ),
    );
  }

  Widget _buildExpensePieChart(BuildContext context,
      Map<String, double> totals, double totalAmount) {
    if (totalAmount == 0) {
      return const Center(
          child: Padding(
        padding: EdgeInsets.all(30.0),
        child: Text('No expenses in this period.'),
      ));
    }

    final pieData = totals.entries.toList().asMap().entries.map((entry) {
      final index = entry.key;
      final data = entry.value;
      final percentage = (data.value / totalAmount) * 100;
      final color = Colors.primaries[index % Colors.primaries.length];

      return PieChartSectionData(
        color: color,
        value: data.value,
        title: '${percentage.toStringAsFixed(1)}%',
        radius: 100,
        titleStyle: const TextStyle(
            fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
        badgeWidget: Text(
          data.key,
          style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onBackground),
        ),
        badgePositionPercentageOffset: 1.05,
      );
    }).toList();

    return Container(
      height: 350,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
      ),
      child: PieChart(
        PieChartData(
          sections: pieData,
          centerSpaceRadius: 40,
          sectionsSpace: 2,
          borderData: FlBorderData(show: false),
        ),
      ),
    );
  }

  Widget _buildLineChart(BuildContext context, List<FlSpot> wealthData,
      String currencySymbol, double minY, double maxY) {
    return Container(
      height: 300,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
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
                      style: const TextStyle(fontSize: 10)),
                ),
              ),
            ),
            bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          borderData: FlBorderData(
            show: true,
            border: Border.all(
                color: Theme.of(context).colorScheme.outline.withOpacity(0.5)),
          ),
          minY: minY < 0 ? minY * 1.1 : 0,
          maxY: (maxY == 0 && minY == 0) ? 100 : maxY * 1.1, // Handle case where max is 0
          lineBarsData: [
            LineChartBarData(
              spots: wealthData.isEmpty ? [const FlSpot(0, 0)] : wealthData, // Handle empty data
              isCurved: true,
              color: Theme.of(context).colorScheme.primary,
              barWidth: 4,
              isStrokeCapRound: true,
              belowBarData: BarAreaData(
                show: true,
                color: Theme.of(context).colorScheme.primary.withOpacity(0.2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBarChart(BuildContext context, double totalIncome,
      double totalExpense, String currencySymbol, double totalMaxY) {
    return Container(
      height: 300,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
      ),
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(
            show: true,
            border: Border.all(
                color: Theme.of(context).colorScheme.outline.withOpacity(0.5)),
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
                      '${value.toStringAsFixed(0)}',
                      style: const TextStyle(fontSize: 10)),
                ),
              ),
            ),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles:false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                getTitlesWidget: (value, meta) {
                  if (value == 0) return const Text('Income');
                  if (value == 1) return const Text('Expense');
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

// --- Settings Widget ---
class SettingsSheet extends StatelessWidget {
  final ThemeMode themeMode;
  final String currencySymbol;
  final List<String> expenseCategories;
  final List<String> incomeCategories;
  final List<Transaction> allTransactions; // NEW: Pass transactions for checking
  final Function(ThemeMode) onUpdateTheme;
  final Function(String) onUpdateCurrency;
  final Function(String, List<String>) onUpdateCategories;
  final Function(String) onImportTransactions;

  const SettingsSheet({
    super.key,
    required this.themeMode,
    required this.currencySymbol,
    required this.expenseCategories,
    required this.incomeCategories,
    required this.allTransactions,
    required this.onUpdateTheme,
    required this.onUpdateCurrency,
    required this.onUpdateCategories,
    required this.onImportTransactions,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        top: 20,
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'App Settings',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const Divider(height: 30),

          // --- Visual Group ---
          Text(
            'Visual',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Theme.of(context).colorScheme.primary),
          ),
          ListTile(
            title: const Text('Dark Mode'),
            trailing: Switch(
              value: themeMode == ThemeMode.dark,
              onChanged: (isDark) {
                onUpdateTheme(isDark ? ThemeMode.dark : ThemeMode.light);
              },
            ),
          ),
          const Divider(height: 30),

          // --- Finance Group ---
          Text(
            'Finance',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Theme.of(context).colorScheme.primary),
          ),
          ListTile(
            title: const Text('Currency Symbol'),
            trailing: DropdownButton<String>(
              value: currencySymbol,
              onChanged: (String? newValue) {
                if (newValue != null) {
                  onUpdateCurrency(newValue);
                }
              },
              items: <String>['\$', '€', '£', '¥']
                  .map<DropdownMenuItem<String>>((String value) {
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(value, style: const TextStyle(fontSize: 20)),
                );
              }).toList(),
            ),
          ),
          
          // --- Category Editors ---
          const SizedBox(height: 20),
          CategoryEditor(
            title: 'Expense Categories',
            type: 'expense',
            categories: expenseCategories,
            allTransactions: allTransactions, // Pass list
            onUpdate: onUpdateCategories,
          ),
          const SizedBox(height: 30),
          CategoryEditor(
            title: 'Income Categories',
            type: 'income',
            categories: incomeCategories,
            allTransactions: allTransactions, // Pass list
            onUpdate: onUpdateCategories,
          ),
          const SizedBox(height: 20),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('Import Transactions'),
            subtitle: const Text('Paste a JSON array or provide a file path'),
            onTap: () {
              final TextEditingController pathController = TextEditingController();
              showDialog<void>(
                context: context,
                builder: (dctx) {
                  return AlertDialog(
                    title: const Text('Import Transactions'),
                    content: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: pathController,
                                  decoration: const InputDecoration(
                                    labelText: 'Path to JSON file',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton.icon(
                                icon: const Icon(Icons.folder_open),
                                label: const Text('Pick'),
                                onPressed: () async {
                                  try {
                                    final result = await FilePicker.platform.pickFiles(
                                      type: FileType.custom,
                                      allowedExtensions: ['json'],
                                    );
                                    if (result != null && result.files.isNotEmpty) {
                                      final fp = result.files.first;
                                      final path = fp.path;
                                      if (path != null) {
                                        pathController.text = path;
                                      }
                                    }
                                  } catch (e) {
                                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('File picker failed: $e')));
                                  }
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const SizedBox(height: 8),
                          const Text('Select a JSON file to import. The existing transactions will be replaced.'),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('Cancel')),
                      TextButton(
                        key: const Key('importDialogImportButton'),
                        onPressed: () async {
                          final path = pathController.text.trim();
                          if (path.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No file selected')));
                            return;
                          }
                          String content;
                          try {
                            final file = File(path);
                            if (!await file.exists()) {
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File not found')));
                              return;
                            }
                            content = await file.readAsString();
                          } catch (e) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to read file: $e')));
                            return;
                          }

                          Navigator.of(dctx).pop();
                          // Call the provided import handler
                          onImportTransactions(content);
                        },
                        child: const Text('Import'),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

// --- Category Editor Widget ---
class CategoryEditor extends StatefulWidget {
  final String title;
  final String type; // 'income' or 'expense'
  final List<String> categories;
  final List<Transaction> allTransactions; // NEW: Receive full list
  final Function(String, List<String>) onUpdate;

  const CategoryEditor({
    super.key,
    required this.title,
    required this.type,
    required this.categories,
    required this.allTransactions,
    required this.onUpdate,
  });

  @override
  State<CategoryEditor> createState() => _CategoryEditorState();
}

class _CategoryEditorState extends State<CategoryEditor> {
  late List<String> _localCategories;
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _localCategories = List.from(widget.categories);
  }
  
  @override
  void didUpdateWidget(covariant CategoryEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.categories != oldWidget.categories) {
      _localCategories = List.from(widget.categories);
    }
  }

  void _addCategory() {
    final newCategory = _controller.text.trim();
    if (newCategory.isNotEmpty && !_localCategories.contains(newCategory)) {
      _localCategories.add(newCategory);
      _controller.clear();
      // No setState() needed, parent update will rebuild
      widget.onUpdate(widget.type, _localCategories); 
    }
  }

  void _removeCategory(String category) {
    // --- FIX for Problem 3: Check if category is in use ---
    final isCategoryInUse = widget.allTransactions.any(
      (txn) => txn.category == category && txn.type == widget.type
    );

    if (isCategoryInUse) {
      // If in use, show an alert and do NOT delete
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Category in Use'),
          content: Text(
              'The category "$category" cannot be deleted because it is used by existing transactions.'),
          actions: [
            TextButton(
              child: const Text('OK'),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      );
    } else {
      // If not in use, proceed with deletion
      _localCategories.remove(category);
      // No setState() needed, parent update will rebuild
      widget.onUpdate(widget.type, _localCategories);
    }
    // --- End of FIX ---
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        // Add new category
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                decoration: const InputDecoration(
                  labelText: 'New Category Name',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _addCategory(),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _addCategory,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(15),
              ),
              child: const Icon(Icons.add),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Spreadsheet-like list (using ListView.builder inside a fixed height container)
        Container(
          height: 200, // Fixed height for spreadsheet-like appearance
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).colorScheme.outline),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListView.builder(
            itemCount: _localCategories.length,
            itemBuilder: (context, index) {
              final category = _localCategories[index];
              return Container(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Theme.of(context).colorScheme.outline.withOpacity(0.5),
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    children: [
                      // Category Name
                      Expanded(
                        child: Text(
                          category,
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                      // Remove button
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.red),
                        onPressed: () => _removeCategory(category),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// --- ClickwheelInputScreen (Unchanged logic) ---
class ClickwheelInputScreen extends StatefulWidget {
  const ClickwheelInputScreen({super.key, required this.title});
  final String title;

  @override
  State<ClickwheelInputScreen> createState() => _ClickwheelInputScreenState();
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
  State<TransactionEditorScreen> createState() => _TransactionEditorScreenState();
}

class _TransactionEditorScreenState extends State<TransactionEditorScreen> {
  late TextEditingController _amountController;
  late String _type; // 'income' or 'expense'
  late String _category;

  @override
  void initState() {
    super.initState();
    _amountController = TextEditingController(text: widget.initial.amount.toStringAsFixed(2));
    _type = widget.initial.type;
    // Initialize category to the initial transaction's category if present,
    // otherwise fall back to the first available category or empty string.
    final initialList = _type == 'expense' ? widget.expenseCategories : widget.incomeCategories;
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
    final categories = _type == 'expense' ? widget.expenseCategories : widget.incomeCategories;

    bool hasCategories = categories.isNotEmpty;

    bool canSave() {
      final text = _amountController.text.trim();
      final value = double.tryParse(text);
      return hasCategories && value != null && value > 0 && _category.isNotEmpty;
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
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: false),
              decoration: const InputDecoration(
                labelText: 'Amount',
                border: OutlineInputBorder(),
                prefixText: '',
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _type,
              decoration: const InputDecoration(labelText: 'Type', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'income', child: Text('Income')),
                DropdownMenuItem(value: 'expense', child: Text('Expense')),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  _type = v;
                  // If the current category isn't in the new list, pick the first available
                  final list = _type == 'expense' ? widget.expenseCategories : widget.incomeCategories;
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
              const Text('Category', style: TextStyle(fontWeight: FontWeight.w600)),
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
                    selectedColor: Theme.of(context).colorScheme.primary.withOpacity(0.2),
                    backgroundColor: Theme.of(context).colorScheme.surfaceVariant,
                    side: selected ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 1.5) : null,
                  );
                }).toList(),
              ),
            ] else ...[
              // When there are no categories available for the chosen type, show guidance.
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Theme.of(context).colorScheme.error.withOpacity(0.08),
                ),
                child: Text(
                  'No categories available for "${_type}". Add categories in Settings before saving.',
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
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.grey.shade300, foregroundColor: Colors.black),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: canSave() ? () {
                      final text = _amountController.text.trim();
                      final value = double.tryParse(text);
                      if (value == null || value <= 0) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a valid amount greater than 0')));
                        return;
                      }
                      final updated = Transaction(
                        amount: value,
                        type: _type,
                        category: _category,
                        date: widget.initial.date,
                      );
                      Navigator.of(context).pop<Transaction>(updated);
                    } : null,
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
class _ClickwheelInputScreenState extends State<ClickwheelInputScreen> {
  int _currentDigit = 0;
  List<int> _inputDigits = [0, 0, 0]; // start from 100s digit by default
  int _currentIndex = 0; // 0 => 100s, 1 => 10s, 2 => 1s, then additional lower digits if appended
  Timer? _digitConfirmationTimer;
  double _currentValue = 0.0;
  // Flash flags for a subtle animation when a digit changes
  List<bool> _flashFlags = [];

  @override
  void initState() {
    super.initState();
    if (_currentIndex < _inputDigits.length) _currentDigit = _inputDigits[_currentIndex];
    _startDigitConfirmationTimer();
  }

  @override
  void dispose() {
    _digitConfirmationTimer?.cancel();
    super.dispose();
  }

  void _incrementDigit() {
    setState(() {
      _currentDigit = (_currentDigit + 1) % 10;
      if (_currentIndex < _inputDigits.length) {
        _inputDigits[_currentIndex] = _currentDigit;
        _ensureFlashFlagsLength();
        _triggerFlash(_currentIndex);
      }
      _updateCurrentValue();
      _resetDigitConfirmationTimer();
    });
  }

  void _decrementDigit() {
    setState(() {
      _currentDigit = (_currentDigit - 1 + 10) % 10;
      if (_currentIndex < _inputDigits.length) {
        _inputDigits[_currentIndex] = _currentDigit;
        _ensureFlashFlagsLength();
        _triggerFlash(_currentIndex);
      }
      _updateCurrentValue();
      _resetDigitConfirmationTimer();
    });
  }

  void _addDigit() {
    setState(() {
      if (_currentIndex < _inputDigits.length) {
        _inputDigits[_currentIndex] = _currentDigit;
        _ensureFlashFlagsLength();
        _triggerFlash(_currentIndex);
      } else {
        _inputDigits.add(_currentDigit);
        _ensureFlashFlagsLength();
        _triggerFlash(_inputDigits.length - 1);
      }
      _currentIndex = _currentIndex + 1;
      if (_currentIndex >= _inputDigits.length) _inputDigits.add(0);
      _currentDigit = _inputDigits[_currentIndex];
      _updateCurrentValue();
      _resetDigitConfirmationTimer();
    });
  }

  void _removeLastDigit() {
    setState(() {
      if (_inputDigits.isNotEmpty) {
        if (_inputDigits.length > 3) {
          _inputDigits.removeLast();
          if (_currentIndex >= _inputDigits.length) _currentIndex = _inputDigits.length - 1;
          _currentDigit = _inputDigits[_currentIndex];
          _ensureFlashFlagsLength();
          _triggerFlash(_currentIndex);
        } else {
          _inputDigits[_currentIndex] = 0;
          _currentDigit = 0;
          _ensureFlashFlagsLength();
          _triggerFlash(_currentIndex);
        }
        _updateCurrentValue();
        _resetDigitConfirmationTimer();
      } else {
        _currentDigit = 0;
        _resetDigitConfirmationTimer();
      }
    });
  }

  void _ensureFlashFlagsLength() {
    while (_flashFlags.length < _inputDigits.length) _flashFlags.add(false);
    if (_flashFlags.length > _inputDigits.length) {
      _flashFlags = _flashFlags.sublist(0, _inputDigits.length);
    }
  }

  void _triggerFlash(int idx) {
    _ensureFlashFlagsLength();
    if (idx < 0 || idx >= _flashFlags.length) return;
    setState(() {
      _flashFlags[idx] = true;
    });
    Future.delayed(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() {
        _flashFlags[idx] = false;
      });
    });
  }

  void _updateCurrentValue() {
    final numStr = _inputDigits.map((e) => e.toString()).join();
    _currentValue = (int.tryParse(numStr) ?? 0) / 100.0;
  }

  void _startDigitConfirmationTimer() {
    _digitConfirmationTimer?.cancel();
    _digitConfirmationTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) _addDigit();
    });
  }

  void _resetDigitConfirmationTimer() => _startDigitConfirmationTimer();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Input Amount:', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),
            Text('${_currentValue.toStringAsFixed(2)}', style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
            const SizedBox(height: 40),
            Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.surfaceVariant,
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 10, offset: const Offset(0, 5))],
              ),
              child: GestureDetector(
                onHorizontalDragEnd: (details) {
                  final vx = details.velocity.pixelsPerSecond.dx;
                  setState(() {
                    if (vx > 100) {
                      _currentIndex = _currentIndex + 1;
                      if (_currentIndex >= _inputDigits.length) _inputDigits.add(0);
                      _currentDigit = _inputDigits[_currentIndex];
                    } else if (vx < -100) {
                      if (_currentIndex > 0) _currentIndex = _currentIndex - 1;
                      _currentDigit = _inputDigits[_currentIndex];
                    }
                    _updateCurrentValue();
                  });
                },
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      top: 10,
                      child: IconButton(icon: const Icon(Icons.keyboard_arrow_up, size: 50), onPressed: _incrementDigit, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: _inputDigits.asMap().entries.map((entry) {
                            final idx = entry.key;
                            final val = entry.value;
                            final selected = idx == _currentIndex;
                            // Animate digit changes with a subtle scale+opacity flash.
                            final isFlashing = idx < _flashFlags.length && _flashFlags[idx];
                            final baseScale = selected ? 1.05 : 1.0;
                            final flashScale = isFlashing ? 1.18 : baseScale;
                            return AnimatedScale(
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOut,
                              scale: flashScale,
                              child: AnimatedOpacity(
                                duration: const Duration(milliseconds: 220),
                                opacity: isFlashing ? 1.0 : (selected ? 1.0 : 0.88),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 6.0),
                                  child: Text(
                                    val.toString(),
                                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                                      fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                                      color: selected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant,
                                      fontSize: selected ? 42 : 24,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 6),
                        Text(_currentIndex == 0 ? '100s' : (_currentIndex == 1 ? '10s' : (_currentIndex == 2 ? '1s' : 'lower')), style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                    Positioned(
                      bottom: 10,
                      child: IconButton(icon: const Icon(Icons.keyboard_arrow_down, size: 50), onPressed: _decrementDigit, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 40),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              ElevatedButton.icon(onPressed: _inputDigits.isNotEmpty ? _removeLastDigit : null, icon: const Icon(Icons.backspace), label: const Text('Back'), style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15))),
              const SizedBox(width: 20),
              ElevatedButton.icon(onPressed: () => Navigator.of(context).pop(_currentValue), icon: const Icon(Icons.done), label: const Text('Done'), style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15), backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Theme.of(context).colorScheme.onPrimary)),
            ]),
          ],
        ),
      ),
    );
  }
}


