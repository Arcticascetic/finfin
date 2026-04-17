import 'package:flutter/material.dart';
import 'dart:async'; // For Timer
import 'dart:convert'; // For JSON encoding/decoding
import 'package:shared_preferences/shared_preferences.dart'; // For saving data
import 'package:fl_chart/fl_chart.dart'; // For charts
import 'package:intl/intl.dart'; // For date formatting
import 'dart:io' show Platform, File;
import 'dart:typed_data'; // For Uint8List
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
// ----------------------------------------------------------------------
// Main Entry Point & App Shell
// ----------------------------------------------------------------------

import 'models/transaction.dart';
import 'models/transactions_notifier.dart';

/// The entry point for the application.
/// Initializes bindings, Hive, and runs the root [BudgetApp].
void main() async {
  // Ensure the app starts with necessary bindings for date formatting
  Intl.defaultLocale = 'en_US';
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  // Wrap the app with a top-level MaterialApp to guarantee MaterialLocalizations
  // are available to any widget that may be built during initialization.
  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: BudgetApp()),
  );
}

// --- Global Default Categories (Used only for first run) ---
const List<String> defaultExpenseCategories = [
  'Housing',
  'Food',
  'Transport',
  'Utilities',
  'Entertainment',
  'Health',
  'Savings',
  'Other Expense',
];

const List<String> defaultIncomeCategories = [
  'Salary',
  'Investments',
  'Gift',
  'Rental Income',
  'Other Income',
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
  final lastDayOfLastMonth = firstDayOfCurrentMonth.subtract(
    const Duration(days: 1),
  );
  final firstDayOfLastMonth = DateTime(
    lastDayOfLastMonth.year,
    lastDayOfLastMonth.month,
    1,
  );
  return DateTimeRange(start: firstDayOfLastMonth, end: lastDayOfLastMonth);
}

// --- Main App Widget (Manages Global State: Theme, Currency, and Filter) ---
class BudgetApp extends StatefulWidget {
  const BudgetApp({super.key});

  @override
  /// Creates the state for the [BudgetApp] widget.
  State<BudgetApp> createState() => _BudgetAppState();
}

class _BudgetAppState extends State<BudgetApp> {
  // Global App Settings State
  String _currencySymbol = '\$';
  ThemeMode _themeMode = ThemeMode.light;
  DateTimeRange? _filterRange; // Null means 'All Time'
  String _inputMethod = 'keyboard'; // Default, will be reset by platform check

  // ScaffoldMessenger Key for showing SnackBars from logic
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  // Dynamic Category State
  List<String> _expenseCategories = [];
  List<String> _incomeCategories = [];

  // Transaction State
  late TransactionsNotifier _transactionsNotifier;
  List<Transaction> get _transactions => _transactionsNotifier.transactions;
  bool _isLoading = true;
  bool _hasError = false;
  String _errorMessage = '';

  @override
  /// Initializes the state, setting up lifecycle listeners or initial values.
  void initState() {
    super.initState();
    // Temporary empty notifier until loaded
    // We'll init properly in _loadSettingsAndData, or better, make it nullable
    // For now, let's just hold it.
    // Actually, we can't make it 'late' if we access it in build before load.
    // Let's rely on _isLoading.
  }

  @override
  /// Cleans up resources, disposing of the transactions notifier.
  void dispose() {
    _transactionsNotifier.dispose();
    super.dispose();
  }

  @override
  /// Called when a dependency of this [State] object changes.
  /// Triggers [didChangeDependencies] to handle dependency updates.
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Initialize here or in initState? initState is better.
    if (_isLoading) _loadSettingsAndData();
  }

  // --- Persistence & Initialization ---

  // Track the current database path (null means default)
  String? _currentDbPath;

  /// Loads settings (theme, currency) and data (categories, transactions).
  ///
  /// This method handles:
  /// 1. SharedPreferences loading for simple settings.
  /// 2. Hive initialization with a timeout to prevent freezes.
  /// 3. Migration from legacy SharedPreferences transaction storage if found.
  /// 4. Initial "Lazy Load" of transactions via [TransactionsNotifier].
  Future<void> _loadSettingsAndData() async {
    final prefs = await SharedPreferences.getInstance();

    // 1. Load Settings
    final savedCurrency = prefs.getString('currencySymbol');
    final isDarkMode = prefs.getBool('isDarkMode') ?? false;
    final savedInputMethod = prefs.getString('inputMethod');
    _currentDbPath = prefs.getString('db_path'); // Load custom path

    // 2. Load Categories (use defaults if none saved)
    final expenseStrings = prefs.getStringList('expenseCategories');
    final incomeStrings = prefs.getStringList('incomeCategories');

    // 3. Load Transactions
    try {
      await Future(() async {
        // Use custom path if available, otherwise default
        final box = await Hive.openBox(
          'transactions_box',
          path: _currentDbPath,
        );
        // Create Notifier
        _transactionsNotifier = TransactionsNotifier(box);
        _transactionsNotifier.addListener(() {
          setState(() {});
        });

        // Check for SharedPreferences migration
        final transactionStrings = prefs.getStringList('transactions');
        if (transactionStrings != null) {
          // Migrate to Hive
          final List<Transaction> migrated = [];
          for (var s in transactionStrings) {
            try {
              final map = json.decode(s) as Map<String, dynamic>;
              migrated.add(Transaction.fromJson(map));
            } catch (_) {}
          }
          // Add to notifier (bulk)
          if (migrated.isNotEmpty) {
            await _transactionsNotifier.addTransactions(migrated);
          }
          // Clear prefs
          await prefs.remove('transactions');
        }

        await _transactionsNotifier.loadFromHive();

        // --- Set Default Filter to Last 30 Days ---
        final now = DateTime.now();
        final start = now.subtract(const Duration(days: 30));
        _filterRange = DateTimeRange(start: start, end: now);

        // Ensure data for this range is loaded
        await _loadDataForRange(_filterRange!);
      }).timeout(const Duration(seconds: 60));
    } on TimeoutException {
      // Emergency Reset: Ask user permission before deleting box
      if (!mounted) return;
      bool? shouldReset = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Database Timeout'),
          content: const Text(
            'The database is taking too long to open. This may indicate a lock or corruption.\n\n'
            'Would you like to delete the database and start fresh? This will erase all data.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                'Delete & Retry',
                style: TextStyle(color: Colors.red),
              ),
            ),
          ],
        ),
      );

      if (shouldReset == true) {
        if (_currentDbPath != null) {
          final file = File('$_currentDbPath/transactions_box.hive');
          if (await file.exists()) await file.delete();
          final lock = File('$_currentDbPath/transactions_box.lock');
          if (await lock.exists()) await lock.delete();
        } else {
          await Hive.deleteBoxFromDisk('transactions_box');
        }

        final box = await Hive.openBox(
          'transactions_box',
          path: _currentDbPath,
        );
        _transactionsNotifier = TransactionsNotifier(box);
        _transactionsNotifier.addListener(() {
          setState(() {});
        });
      } else {
        // User cancelled, show error state
        if (mounted) {
          setState(() {
            _errorMessage =
                'Database initialization timed out and reset was cancelled.';
            _isLoading = false;
          });
        }
        return;
      }
    } catch (e) {
      debugPrint('Initialization Error: $e');
      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
      return; // Stop execution here
    }

    if (!mounted) return;

    setState(() {
      _currencySymbol = savedCurrency ?? '\$';
      _themeMode = isDarkMode ? ThemeMode.dark : ThemeMode.light;

      if (savedInputMethod != null) {
        _inputMethod = savedInputMethod;
      } else {
        // Default based on Platform
        if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
          _inputMethod = 'clickwheel';
        } else {
          _inputMethod = 'keyboard';
        }
      }

      _expenseCategories = expenseStrings ?? defaultExpenseCategories;
      _incomeCategories = incomeStrings ?? defaultIncomeCategories;

      _isLoading = false;
    });
  }

  /// Saves the current list of expense and income categories to SharedPreferences.
  Future<void> _saveCategories() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('expenseCategories', _expenseCategories);
    await prefs.setStringList('incomeCategories', _incomeCategories);
  }

  /// Saves application settings such as currency and theme mode.
  Future<void> _saveSettings({String? currency, ThemeMode? mode}) async {
    final prefs = await SharedPreferences.getInstance();
    if (currency != null) {
      await prefs.setString('currencySymbol', currency);
    }
    if (mode != null) {
      await prefs.setBool('isDarkMode', mode == ThemeMode.dark);
    }
    await prefs.setString('inputMethod', _inputMethod);
  }

  // --- App Logic Methods ---

  /// Adds a new transaction with the specified [amount], [type], and [category].
  void _addTransaction(double amount, String type, String category) {
    // Create new transaction with ID (generated by constructor)
    final t = Transaction(
      amount: amount,
      type: type,
      category: category,
      date: DateTime.now(),
    );
    _transactionsNotifier.addTransaction(t);
  }

  /// Removes the specified [transactionToRemove] from the list.
  void _removeTransaction(Transaction transactionToRemove) {
    _transactionsNotifier.removeTransaction(transactionToRemove);
  }

  /// Replace an existing transaction with an updated one.
  /// This supports editing amount, type, and category.
  void _updateTransaction(
    Transaction oldTransaction,
    Transaction newTransaction,
  ) {
    // Use ID matching for robust lookup
    final idx = _transactions.indexWhere((t) => t.id == oldTransaction.id);
    if (idx != -1) {
      _transactionsNotifier.updateTransaction(oldTransaction, newTransaction);
    }
  }

  /// Updates the theme mode of the application.
  void _updateThemeMode(ThemeMode newMode) {
    setState(() {
      _themeMode = newMode;
    });
    _saveSettings(mode: newMode);
  }

  /// Updates the currency symbol used throughout the app.
  void _updateCurrency(String newCurrency) {
    setState(() {
      _currencySymbol = newCurrency;
    });
    _saveSettings(currency: newCurrency);
  }

  /// Updates the input method (keyboard/clickwheel).
  void _updateInputMethod(String method) {
    setState(() {
      _inputMethod = method;
    });
    _saveSettings();
  }

  /// Updates the date range filter for transactions.
  void _updateFilterRange(DateTimeRange? newRange) {
    setState(() {
      _filterRange = newRange;
    });

    // Auto-load transactions for the selected range
    if (newRange != null) {
      _loadDataForRange(newRange);
    }
  }

  /// Ensures transactions for all months within the given range are loaded.
  Future<void> _loadDataForRange(DateTimeRange range) async {
    DateTime monthIterator = DateTime(range.start.year, range.start.month);
    final endMonth = DateTime(range.end.year, range.end.month);

    while (monthIterator.isBefore(endMonth) ||
        monthIterator.isAtSameMomentAs(endMonth)) {
      final yyyyMM = DateFormat('yyyyMM').format(monthIterator);
      if (!_transactionsNotifier.loadedMonths.contains(yyyyMM)) {
        await _transactionsNotifier.loadMonth(yyyyMM);
      }

      // Move to next month
      monthIterator = DateTime(monthIterator.year, monthIterator.month + 1);
    }
  }

  /// Updates the category list for a specific [type] (expense or income).
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
  /// Returns a list of transactions filtered by the current [_filterRange].
  List<Transaction> get _filteredTransactions {
    if (_filterRange == null) {
      return _transactions;
    }
    // Filter logic: includes transactions from start date up to the end of the end date
    return _transactions.where((t) {
      final isAfterStart = t.date.isAfter(
        _filterRange!.start.subtract(const Duration(microseconds: 1)),
      );
      final isBeforeEnd = t.date.isBefore(
        _filterRange!.end
            .add(const Duration(days: 1))
            .subtract(const Duration(microseconds: 1)),
      );
      return isAfterStart && isBeforeEnd;
    }).toList();
  }

  // --- Build Method ---
  @override
  /// Builds the main widget tree for the application.
  Widget build(BuildContext context) {
    // Use a premium FlexScheme
    const FlexScheme usedScheme = FlexScheme.bahamaBlue;

    return MaterialApp(
      scaffoldMessengerKey: _scaffoldMessengerKey,
      title: 'FinFin',
      theme: FlexThemeData.light(
        scheme: usedScheme,
        surfaceMode: FlexSurfaceMode.levelSurfacesLowScaffold,
        blendLevel: 7,
        subThemesData: const FlexSubThemesData(
          blendOnLevel: 10,
          blendOnColors: false,
          useMaterial3Typography: true,
          useM2StyleDividerInM3: true,
          defaultRadius: 12.0,
          elevatedButtonSchemeColor: SchemeColor.onPrimaryContainer,
          elevatedButtonSecondarySchemeColor: SchemeColor.primaryContainer,
          outlinedButtonOutlineSchemeColor: SchemeColor.primary,
          toggleButtonsBorderSchemeColor: SchemeColor.primary,
          inputDecoratorSchemeColor: SchemeColor.primary,
          inputDecoratorIsFilled: false,
          inputDecoratorRadius: 12.0,
          inputDecoratorUnfocusedHasBorder: false,
        ),
        visualDensity: FlexColorScheme.comfortablePlatformDensity,
        useMaterial3: true,
        swapLegacyOnMaterial3: true,
        fontFamily: 'Outfit', // Uses local asset
      ),
      darkTheme: FlexThemeData.dark(
        scheme: usedScheme,
        surfaceMode: FlexSurfaceMode.levelSurfacesLowScaffold,
        blendLevel: 13,
        subThemesData: const FlexSubThemesData(
          blendOnLevel: 20,
          useMaterial3Typography: true,
          useM2StyleDividerInM3: true,
          defaultRadius: 12.0,
          inputDecoratorSchemeColor: SchemeColor.primary,
          inputDecoratorIsFilled: false,
          inputDecoratorRadius: 12.0,
          inputDecoratorUnfocusedHasBorder: false,
        ),
        visualDensity: FlexColorScheme.comfortablePlatformDensity,
        useMaterial3: true,
        swapLegacyOnMaterial3: true,
        fontFamily: 'Outfit',
      ),
      themeMode: _themeMode,
      home: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('FinFin'),
            backgroundColor: Theme.of(context).colorScheme.inversePrimary,
            actions: [
              IconButton(
                icon: const Icon(Icons.settings),
                onPressed: () => _showSettings(context),
              ),
            ],
            bottom: const TabBar(
              tabs: [
                Tab(icon: Icon(Icons.list_alt), text: 'Transactions'),
                Tab(icon: Icon(Icons.show_chart), text: 'Charts'),
              ],
            ),
          ),
          body: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _hasError
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.error_outline,
                          size: 48,
                          color: Colors.red,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Failed to load application data.\n\n$_errorMessage',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.red),
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton(
                          onPressed: () {
                            setState(() {
                              _isLoading = true;
                              _hasError = false;
                            });
                            _loadSettingsAndData();
                          },
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
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
                      availableMonths: _transactionsNotifier.availableMonths,
                      loadedMonths: _transactionsNotifier.loadedMonths,
                      totalBalance: _transactionsNotifier.totalBalance,
                      onAddTransaction: _addTransaction,
                      onRemoveTransaction: _removeTransaction,
                      onEditTransaction: _updateTransaction,
                      onUpdateFilter: _updateFilterRange,
                      onLoadMonth: (month) =>
                          _transactionsNotifier.loadMonth(month),
                      monthSummaries: _transactionsNotifier.monthSummaries,
                      inputMethod: _inputMethod,
                    ),
                    // --- Tab 2: Chart Screen ---
                    ChartScreen(
                      transactions: _filteredTransactions,
                      allTransactions: _transactions,
                      currencySymbol: _currencySymbol,
                      onLoadMonth: (month) =>
                          _transactionsNotifier.loadMonth(month),
                      filterRange: _filterRange,
                      onUpdateFilter: _updateFilterRange,
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  // --- Settings Modal Bottom Sheet ---
  /// Displays the settings modal bottom sheet.
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
          onImportTransactions: (jsonString) =>
              _importTransactionsFromJsonString(ctx, jsonString),
          currentDbPath: _currentDbPath,
          onChangeDatabasePath: () async {
            Navigator.pop(ctx);
            _changeDatabaseLocation();
          },
          onExportData: (format) async {
            Navigator.pop(ctx);
            _exportData(format);
          },
          onResetData: () async {
            Navigator.pop(ctx); // Close settings first
            _confirmAndResetData();
          },
          inputMethod: _inputMethod,
          onUpdateInputMethod: _updateInputMethod,
        );
      },
    );
  }

  /// Shows a confirmation dialog and resets all transaction data if confirmed.
  Future<void> _confirmAndResetData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset All Data?'),
        content: const Text(
          'This will permanently delete ALL transactions. This action cannot be undone.\n\nCategories and settings will be preserved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _transactionsNotifier.clearAllTransactions();
      await _transactionsNotifier.clearAllTransactions();
      if (mounted) {
        _scaffoldMessengerKey.currentState?.showSnackBar(
          const SnackBar(
            content: Text('All transactions have been erased.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Import transactions from a JSON string. Accepts either:
  /// - A JSON array of strings (each string is a JSON-encoded transaction map), or
  /// - A JSON array of maps (each is a transaction map).
  /// This replaces any existing transactions (old data is deleted) and persists the new set.
  Future<void> _importTransactionsFromJsonString(
    BuildContext ctx,
    String jsonString,
  ) async {
    bool dialogShown = false;
    final counts = ValueNotifier<Map<String, int>>({
      'total': 0,
      'processed': 0,
      'imported': 0,
      'skipped': 0,
    });
    try {
      final decoded = json.decode(jsonString);
      if (decoded is! List) {
        throw const FormatException('Top-level JSON value must be an array');
      }

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
      // Replace existing transactions with the new parsed list
      // Use notifier import
      await _transactionsNotifier.importFromDecodedList(decoded, counts);

      // close the progress dialog
      if (dialogShown && ctx.mounted) Navigator.of(ctx).pop();
      dialogShown = false;

      // Show final result
      final importedCount = counts.value['imported'] ?? 0;
      final skippedCount = counts.value['skipped'] ?? 0;
      if (ctx.mounted) {
        showDialog(
          context: ctx,
          builder: (dctx) => AlertDialog(
            title: const Text('Import Complete'),
            content: Text(
              'Imported $importedCount transactions. Skipped $skippedCount invalid entries.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      if (ctx.mounted) {
        // Use key as well for consistency although ctx might work here because it is from showDialog builder which is under the MaterialApp
        // But safer to use key if ctx is from Dialog
        _scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text(
              'Imported $importedCount transactions (skipped $skippedCount).',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
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
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } finally {
      counts.dispose();
    }
  }

  // --- Database Location & Export Logic ---

  /// Handles the logic for moving the database to a new user-selected location.
  Future<void> _changeDatabaseLocation() async {
    try {
      final String? selectedDirectory = await getDirectoryPath();
      if (selectedDirectory == null) return; // User canceled

      // Confirm with user
      if (!mounted) return;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Change Database Location?'),
          content: Text(
            'This will move your database to:\n$selectedDirectory\n\n'
            'The app will reload regardless of whether moving succeeds entirely. '
            'Ensure you have write permissions.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      );

      if (confirm != true) return;

      setState(() {
        _isLoading = true;
      });

      // 1. Get current paths
      // If _currentDbPath is null, it's in default Hive location.
      // We can't easily iterate default hive path from here without knowing it.
      // But Hive.box('transactions_box').path gives the full path.
      final Box box = Hive.box('transactions_box');
      final String? oldPath = box.path;

      // 2. Close box to release lock
      await box.close();

      if (oldPath != null) {
        // 3. Move files
        final File oldDbFile = File(oldPath);
        final String filename = oldDbFile.uri.pathSegments.last;
        if (await oldDbFile.exists()) {
          try {
            await oldDbFile.copy('$selectedDirectory/$filename');
            // We can optionally delete the old one, but keeping it as backup is safer for now?
            // Users might want "Move", but "Copy" is safer.
            // Let's Copy.
          } catch (e) {
            // If copy fails, we haven't updated prefs yet, so we just restart and it reopens old one.
            if (mounted) {
              _scaffoldMessengerKey.currentState?.showSnackBar(
                SnackBar(content: Text('Failed to copy database: $e')),
              );
            }
            _loadSettingsAndData(); // Re-open old
            return;
          }
        }
      }

      // 4. Update Prefs
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('db_path', selectedDirectory);

      // 5. Reload
      await _loadSettingsAndData();
    } catch (e) {
      if (mounted) {
        _scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text('Error changing location: $e')),
        );
        setState(() => _isLoading = false);
      }
    }
  }

  /// Exports transaction data to a file in the specified [format] (json or csv).
  Future<void> _exportData(String format) async {
    try {
      final transactions = _transactions; // Get current list
      String content = '';
      String mimeType = '';
      String extension = '';

      if (format == 'json') {
        content = jsonEncode(transactions.map((e) => e.toJson()).toList());
        mimeType = 'application/json';
        extension = 'json';
      } else if (format == 'csv') {
        final buffer = StringBuffer();
        // Header
        buffer.writeln('Date,Amount,Type,Category,ID');
        for (var t in transactions) {
          // simple CSV escaping: quote fields if they contain commas
          /// Escapes special characters for CSV format.
          String escape(String s) {
            if (s.contains(',')) return '"$s"';
            return s;
          }

          buffer.write(
            DateTime.parse(t.date.toIso8601String()).toLocal().toString(),
          );
          buffer.write(',');
          buffer.write(t.amount);
          buffer.write(',');
          buffer.write(escape(t.type));
          buffer.write(',');
          buffer.write(escape(t.category));
          buffer.write(',');
          buffer.write(t.id);
          buffer.writeln();
        }
        content = buffer.toString();
        mimeType = 'text/csv';
        extension = 'csv';
      }

      final fileName =
          'transactions_export_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.$extension';

      // Use file_selector to save
      final FileSaveLocation? result = await getSaveLocation(
        suggestedName: fileName,
        acceptedTypeGroups: [
          XTypeGroup(
            label: format.toUpperCase(),
            extensions: [extension],
            mimeTypes: [mimeType],
          ),
        ],
      );

      if (result == null) {
        // User canceled
        return;
      }

      final Uint8List fileData = Uint8List.fromList(utf8.encode(content));
      final XFile textFile = XFile.fromData(
        fileData,
        mimeType: mimeType,
        name: fileName,
      );
      await textFile.saveTo(result.path);

      if (mounted) {
        _scaffoldMessengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('Export successful')),
        );
      }
    } catch (e) {
      if (mounted) {
        _scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }
}

// --- Category Selection Screen ---
class CategorySelectionScreen extends StatelessWidget {
  final String type; // 'income' or 'expense'
  final List<String> categories;
  final Function(double, String, String) onConfirmTransaction;
  final String inputMethod;

  const CategorySelectionScreen({
    super.key,
    required this.type,
    required this.categories,
    required this.onConfirmTransaction,
    required this.inputMethod,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${type == 'expense' ? 'Select Expense' : 'Select Income'} Category',
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: categories.isEmpty
          ? const Center(
              child: Text('No categories defined. Add them in Settings.'),
            )
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
                    if (inputMethod == 'clickwheel') {
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
                    } else {
                      // Keyboard Input: Use TransactionEditorScreen
                      final dummyTx = Transaction(
                        amount: 0,
                        type: type,
                        category: category,
                        date: DateTime.now(),
                      );
                      final result = await Navigator.of(context)
                          .push<Transaction>(
                            MaterialPageRoute(
                              fullscreenDialog: true,
                              builder: (ctx) => TransactionEditorScreen(
                                initial: dummyTx,
                                expenseCategories: type == 'expense'
                                    ? categories
                                    : [],
                                incomeCategories: type == 'income'
                                    ? categories
                                    : [],
                              ),
                            ),
                          );

                      if (result != null) {
                        onConfirmTransaction(
                          result.amount,
                          result.type,
                          result.category,
                        );
                        if (context.mounted) Navigator.of(context).pop();
                      }
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    foregroundColor: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant,
                    elevation: 4,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    category,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                );
              },
            ),
    );
  }
}

// --- HomeScreen with Year/Month grouping (collapsible mother transactions) ---
/// The main screen displaying the list of transactions.
///
/// It supports:
/// - Filtering by date range.
/// - Grouping transactions by Year and Month.
/// - Lazy loading of monthly data (via expanding month tiles).
/// - Deleting and editing transactions.
class HomeScreen extends StatefulWidget {
  final List<Transaction> transactions;
  final List<Transaction> allTransactions;
  final String currencySymbol;
  final DateTimeRange? filterRange;
  final List<String> expenseCategories;
  final List<String> incomeCategories;

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

// --- ChartScreen with duration selector ---

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

// --- Settings Widget ---
class SettingsSheet extends StatelessWidget {
  final ThemeMode themeMode;
  final String currencySymbol;
  final List<String> expenseCategories;
  final List<String> incomeCategories;
  final List<Transaction>
  allTransactions; // NEW: Pass transactions for checking
  final Function(ThemeMode) onUpdateTheme;
  final Function(String) onUpdateCurrency;
  final Function(String, List<String>) onUpdateCategories;
  final Function(String) onImportTransactions;
  final String? currentDbPath;
  final VoidCallback onChangeDatabasePath;
  final Function(String) onExportData;
  final VoidCallback onResetData;
  final String inputMethod;
  final Function(String) onUpdateInputMethod;

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
    this.currentDbPath,
    required this.onChangeDatabasePath,
    required this.onExportData,
    required this.onResetData,
    required this.inputMethod,
    required this.onUpdateInputMethod,
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
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const Divider(height: 30),

          // --- Visual Group ---
          Text(
            'Visual',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
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
          ListTile(
            title: const Text('Input Method'),
            subtitle: const Text('Entry mode for amounts'),
            trailing: DropdownButton<String>(
              value: inputMethod,
              onChanged: (val) {
                if (val != null) onUpdateInputMethod(val);
              },
              items: const [
                DropdownMenuItem(value: 'keyboard', child: Text('Keyboard')),
                DropdownMenuItem(
                  value: 'clickwheel',
                  child: Text('Clickwheel'),
                ),
              ],
            ),
          ),
          const Divider(height: 30),

          // --- Finance Group ---
          Text(
            'Finance',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
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
                  })
                  .toList(),
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
            title: const Text('Import from JSON'),
            onTap: () async {
              // ...
            },
          ),

          const Divider(height: 30),

          // --- Data Management Group ---
          Text(
            'Data Management',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.folder_open),
            title: const Text('Database Location'),
            subtitle: Text(
              currentDbPath ?? 'Default Storage',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: onChangeDatabasePath,
          ),
          ExpansionTile(
            leading: const Icon(Icons.download),
            title: const Text('Export Data'),
            children: [
              ListTile(
                leading: const Icon(Icons.data_object),
                title: const Text('Export as JSON'),
                onTap: () => onExportData('json'),
              ),
              ListTile(
                leading: const Icon(Icons.table_chart),
                title: const Text('Export as CSV'),
                onTap: () => onExportData('csv'),
              ),
            ],
          ),

          const SizedBox(height: 20),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('Import from JSON'),
            subtitle: const Text('Paste a JSON array or provide a file path'),
            onTap: () {
              final TextEditingController pathController =
                  TextEditingController();
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
                                    const XTypeGroup typeGroup = XTypeGroup(
                                      label: 'JSON Files',
                                      extensions: <String>['json'],
                                    );
                                    final XFile? file = await openFile(
                                      acceptedTypeGroups: <XTypeGroup>[
                                        typeGroup,
                                      ],
                                    );
                                    if (file != null) {
                                      pathController.text = file.path;
                                    }
                                  } catch (e) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('File picker failed: $e'),
                                      ),
                                    );
                                  }
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Select a JSON file to import. The existing transactions will be replaced.',
                          ),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(dctx).pop(),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        key: const Key('importDialogImportButton'),
                        onPressed: () async {
                          final path = pathController.text.trim();
                          if (path.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('No file selected')),
                            );
                            return;
                          }
                          String content;
                          try {
                            final file = File(path);
                            if (!await file.exists()) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('File not found')),
                              );
                              return;
                            }
                            content = await file.readAsString();
                          } catch (e) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Failed to read file: $e'),
                              ),
                            );
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

          const Divider(height: 30),

          // --- Data Management Group ---
          Text(
            'Data Management',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.folder_open),
            title: const Text('Database Location'),
            subtitle: Text(
              currentDbPath ?? 'Default Storage',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: onChangeDatabasePath,
          ),
          ExpansionTile(
            leading: const Icon(Icons.download),
            title: const Text('Export Data'),
            children: [
              ListTile(
                leading: const Icon(Icons.data_object),
                title: const Text('Export as JSON'),
                onTap: () => onExportData('json'),
              ),
              ListTile(
                leading: const Icon(Icons.table_chart),
                title: const Text('Export as CSV'),
                onTap: () => onExportData('csv'),
              ),
            ],
          ),

          const SizedBox(height: 20),
          Center(
            child: TextButton.icon(
              onPressed: onResetData,
              icon: const Icon(Icons.delete_forever, color: Colors.red),
              label: const Text(
                'Reset All Data',
                style: TextStyle(color: Colors.red),
              ),
            ),
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
      (txn) => txn.category == category && txn.type == widget.type,
    );

    if (isCategoryInUse) {
      // If in use, show an alert and do NOT delete
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Category in Use'),
          content: Text(
            'The category "$category" cannot be deleted because it is used by existing transactions.',
          ),
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
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
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
                      color: Theme.of(
                        context,
                      ).colorScheme.outline.withAlpha((0.5 * 255).round()),
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
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Colors.red,
                        ),
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

class _ClickwheelInputScreenState extends State<ClickwheelInputScreen> {
  int _currentDigit = 0;
  final List<int> _inputDigits = [0, 0, 0]; // start from 100s digit by default
  int _currentIndex =
      0; // 0 => 100s, 1 => 10s, 2 => 1s, then additional lower digits if appended
  double _currentValue = 0.0;
  // Flash flags for a subtle animation when a digit changes
  List<bool> _flashFlags = [];

  @override
  void initState() {
    super.initState();
    if (_currentIndex < _inputDigits.length) {
      _currentDigit = _inputDigits[_currentIndex];
    }
  }

  /// Increments the current digit, wrapping around 0-9.
  /// Also updates the visual state and resets the confirmation timer.
  void _incrementDigit() {
    setState(() {
      _currentDigit = (_currentDigit + 1) % 10;
      if (_currentIndex < _inputDigits.length) {
        _inputDigits[_currentIndex] = _currentDigit;
        _ensureFlashFlagsLength();
        _triggerFlash(_currentIndex);
      }
      _updateCurrentValue();
    });
  }

  /// Decrements the current digit, wrapping around 0-9.
  /// Also updates the visual state and resets the confirmation timer.
  void _decrementDigit() {
    setState(() {
      _currentDigit = (_currentDigit - 1 + 10) % 10;
      if (_currentIndex < _inputDigits.length) {
        _inputDigits[_currentIndex] = _currentDigit;
        _ensureFlashFlagsLength();
        _triggerFlash(_currentIndex);
      }
      _updateCurrentValue();
    });
  }


  /// Removes the last digit or resets the current one if it's the only one.
  /// Handles navigation back to the previous digit if applicable.
  void _removeLastDigit() {
    setState(() {
      if (_inputDigits.isNotEmpty) {
        if (_inputDigits.length > 3) {
          _inputDigits.removeLast();
          if (_currentIndex >= _inputDigits.length) {
            _currentIndex = _inputDigits.length - 1;
          }
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
      } else {
        _currentDigit = 0;
      }
    });
  }

  /// Ensures the flash flags list matches the length of the input digits.
  void _ensureFlashFlagsLength() {
    while (_flashFlags.length < _inputDigits.length) {
      _flashFlags.add(false);
    }
    if (_flashFlags.length > _inputDigits.length) {
      _flashFlags = _flashFlags.sublist(0, _inputDigits.length);
    }
  }

  /// Triggers a brief flash animation for the digit at [idx].
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

  /// Updates the double value based on the current list of digits.
  /// Assumes the input represents a value in cents/hundreths.
  void _updateCurrentValue() {
    final numStr = _inputDigits.map((e) => e.toString()).join();
    _currentValue = (int.tryParse(numStr) ?? 0) / 100.0;
  }

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
            Text(
              'Input Amount:',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 10),
            Text(
              _currentValue.toStringAsFixed(2),
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 40),
            Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha((0.2 * 255).round()),
                    blurRadius: 10,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: GestureDetector(
                onHorizontalDragEnd: (details) {
                  final vx = details.velocity.pixelsPerSecond.dx;
                  setState(() {
                    if (vx < -100) {
                      // Swipe Left -> Next Digit
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
                      if (_currentIndex >= _inputDigits.length) {
                        _inputDigits.add(0);
                      }
                      _currentDigit = _inputDigits[_currentIndex];
                    } else if (vx > 100) {
                      // Swipe Right -> Previous Digit
                      if (_currentIndex > 0) {
                        // Save current before leaving?
                        if (_currentIndex < _inputDigits.length) {
                          _inputDigits[_currentIndex] = _currentDigit;
                        }
                        _currentIndex = _currentIndex - 1;
                        _currentDigit = _inputDigits[_currentIndex];
                        _ensureFlashFlagsLength();
                        _triggerFlash(_currentIndex);
                      }
                    }
                    _updateCurrentValue();
                  });
                },
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      top: 10,
                      child: IconButton(
                        icon: const Icon(Icons.keyboard_arrow_up, size: 50),
                        onPressed: _incrementDigit,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
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
                            final isFlashing =
                                idx < _flashFlags.length && _flashFlags[idx];
                            final baseScale = selected ? 1.05 : 1.0;
                            final flashScale = isFlashing ? 1.18 : baseScale;
                            return AnimatedScale(
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOut,
                              scale: flashScale,
                              child: AnimatedOpacity(
                                duration: const Duration(milliseconds: 220),
                                opacity: isFlashing
                                    ? 1.0
                                    : (selected ? 1.0 : 0.88),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6.0,
                                  ),
                                  child: Text(
                                    val.toString(),
                                    style: Theme.of(context)
                                        .textTheme
                                        .displaySmall
                                        ?.copyWith(
                                          fontWeight: selected
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                          color: selected
                                              ? Theme.of(
                                                  context,
                                                ).colorScheme.primary
                                              : Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                          fontSize: selected ? 42 : 24,
                                        ),
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _currentIndex == 0
                              ? '100s'
                              : (_currentIndex == 1
                                    ? '10s'
                                    : (_currentIndex == 2 ? '1s' : 'lower')),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                    Positioned(
                      bottom: 10,
                      child: IconButton(
                        icon: const Icon(Icons.keyboard_arrow_down, size: 50),
                        onPressed: _decrementDigit,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 40),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _inputDigits.isNotEmpty ? _removeLastDigit : null,
                  icon: const Icon(Icons.backspace),
                  label: const Text('Back'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 15,
                    ),
                  ),
                ),
                const SizedBox(width: 20),
                ElevatedButton.icon(
                  onPressed: () => Navigator.of(context).pop(_currentValue),
                  icon: const Icon(Icons.done),
                  label: const Text('Done'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 15,
                    ),
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
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
