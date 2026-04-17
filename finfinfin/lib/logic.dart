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

import 'models/transaction.dart';
import 'models/transactions_notifier.dart';
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
class AppLogic extends ChangeNotifier {
  // Global App Settings State
  String currencySymbol = '\$';
  ThemeMode themeMode = ThemeMode.light;
  DateTimeRange? filterRange; // Null means 'All Time'
  String inputMethod = 'keyboard'; // Default, will be reset by platform check

  // ScaffoldMessenger Key for showing SnackBars from logic
  final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  // Dynamic Category State
  List<String> expenseCategories = [];
  Map<String, double> expenseCategoryLimits = {};
  List<String> incomeCategories = [];

  // Transaction State
  late TransactionsNotifier transactionsNotifier;
  List<Transaction> get transactions => transactionsNotifier.transactions;
  bool isLoading = true;
  bool hasError = false;
  String errorMessage = '';

  void init() {
    // Temporary empty notifier until loaded
    // We'll init properly in loadSettingsAndData, or better, make it nullable
    // For now, let's just hold it.
    // Actually, we can't make it 'late' if we access it in build before load.
    // Let's rely on isLoading.
  }

  @override
  void dispose() {
    transactionsNotifier.dispose();
    super.dispose();
  }

  void didChangeDependencies(BuildContext context) {
    // Initialize here or in initState? initState is better.
    if (isLoading) loadSettingsAndData(context);
  }

  // --- Persistence & Initialization ---

  // Track the current database path (null means default)
  String? currentDbPath;

  /// Loads settings (theme, currency) and data (categories, transactions).
  ///
  /// This method handles:
  /// 1. SharedPreferences loading for simple settings.
  /// 2. Hive initialization with a timeout to prevent freezes.
  /// 3. Migration from legacy SharedPreferences transaction storage if found.
  /// 4. Initial "Lazy Load" of transactions via [TransactionsNotifier].
  Future<void> loadSettingsAndData(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();

    // 1. Load Settings
    final savedCurrency = prefs.getString('currencySymbol');
    final isDarkMode = prefs.getBool('isDarkMode') ?? false;
    final savedInputMethod = prefs.getString('inputMethod');
    currentDbPath = prefs.getString('db_path'); // Load custom path

    // 2. Load Categories (use defaults if none saved)
    final expenseStrings = prefs.getStringList('expenseCategories');
    final limitStrings = prefs.getStringList('expenseCategoryLimits');
    if (limitStrings != null) {
      for (final s in limitStrings) {
        final parts = s.split(':');
        if (parts.length == 2) {
          expenseCategoryLimits[parts[0]] = double.tryParse(parts[1]) ?? 0.0;
        }
      }
    }
    final incomeStrings = prefs.getStringList('incomeCategories');

    // 3. Load Transactions
    try {
      await Future(() async {
        // Use custom path if available, otherwise default
        final box = await Hive.openBox(
          'transactions_box',
          path: currentDbPath,
        );
        // Create Notifier
        transactionsNotifier = TransactionsNotifier(box);
        transactionsNotifier.addListener(() {
          
    notifyListeners();
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
            await transactionsNotifier.addTransactions(migrated);
          }
          // Clear prefs
          await prefs.remove('transactions');
        }

        await transactionsNotifier.loadFromHive();

        // --- Set Default Filter to Last 30 Days ---
        final now = DateTime.now();
        final start = now.subtract(const Duration(days: 30));
        filterRange = DateTimeRange(start: start, end: now);

        // Ensure data for this range is loaded
        await _loadDataForRange(filterRange!);
      }).timeout(const Duration(seconds: 60));
    } on TimeoutException {
      // Emergency Reset: Ask user permission before deleting box
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
        if (currentDbPath != null) {
          final file = File('$currentDbPath/transactions_box.hive');
          if (await file.exists()) await file.delete();
          final lock = File('$currentDbPath/transactions_box.lock');
          if (await lock.exists()) await lock.delete();
        } else {
          await Hive.deleteBoxFromDisk('transactions_box');
        }

        final box = await Hive.openBox(
          'transactions_box',
          path: currentDbPath,
        );
        transactionsNotifier = TransactionsNotifier(box);
        transactionsNotifier.addListener(() {
          
    notifyListeners();
        });
      } else {
        // User cancelled, show error state
        if (true) {
          
            errorMessage =
                'Database initialization timed out and reset was cancelled.';
            isLoading = false;
          
    notifyListeners();
        }
        return;
      }
    } catch (e) {
      debugPrint('Initialization Error: $e');
      if (true) {
        
          hasError = true;
          errorMessage = e.toString();
          isLoading = false;
        
    notifyListeners();
      }
      return; // Stop execution here
    }

    
    
      currencySymbol = savedCurrency ?? '\$';
      themeMode = isDarkMode ? ThemeMode.dark : ThemeMode.light;

      if (savedInputMethod != null) {
        inputMethod = savedInputMethod;
      } else {
        // Default based on Platform
        if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
          inputMethod = 'clickwheel';
        } else {
          inputMethod = 'keyboard';
        }
      }

      expenseCategories = expenseStrings ?? defaultExpenseCategories;
      incomeCategories = incomeStrings ?? defaultIncomeCategories;

      isLoading = false;
    
    notifyListeners();
  }

  /// Saves the current list of expense and income categories to SharedPreferences.
  Future<void> saveCategories() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('expenseCategories', expenseCategories);
    await prefs.setStringList('incomeCategories', incomeCategories);
    final limitList = expenseCategoryLimits.entries.map((e) => '${e.key}:${e.value}').toList();
    await prefs.setStringList('expenseCategoryLimits', limitList);
  }

  void updateCategoryLimits(Map<String, double> newLimits) {
    expenseCategoryLimits = newLimits;
    notifyListeners();
    saveCategories();
  }


  /// Saves application settings such as currency and theme mode.
  Future<void> saveSettings({String? currency, ThemeMode? mode}) async {
    final prefs = await SharedPreferences.getInstance();
    if (currency != null) {
      await prefs.setString('currencySymbol', currency);
    }
    if (mode != null) {
      await prefs.setBool('isDarkMode', mode == ThemeMode.dark);
    }
    await prefs.setString('inputMethod', inputMethod);
  }

  // --- App Logic Methods ---

  /// Adds a new transaction with the specified [amount], [type], and [category].
  void addTransaction(double amount, String type, String category) {
    // Create new transaction with ID (generated by constructor)
    final t = Transaction(
      amount: amount,
      type: type,
      category: category,
      date: DateTime.now(),
    );
    transactionsNotifier.addTransaction(t);
  }

  /// Removes the specified [transactionToRemove] from the list.
  void removeTransaction(Transaction transactionToRemove) {
    transactionsNotifier.removeTransaction(transactionToRemove);
  }

  /// Replace an existing transaction with an updated one.
  /// This supports editing amount, type, and category.
  void updateTransaction(
    Transaction oldTransaction,
    Transaction newTransaction,
  ) {
    // Use ID matching for robust lookup
    final idx = transactions.indexWhere((t) => t.id == oldTransaction.id);
    if (idx != -1) {
      transactionsNotifier.updateTransaction(oldTransaction, newTransaction);
    }
  }

  /// Updates the theme mode of the application.
  void updateThemeMode(ThemeMode newMode) {
    
      themeMode = newMode;
    
    notifyListeners();
    saveSettings(mode: newMode);
  }

  /// Updates the currency symbol used throughout the app.
  void updateCurrency(String newCurrency) {
    
      currencySymbol = newCurrency;
    
    notifyListeners();
    saveSettings(currency: newCurrency);
  }

  /// Updates the input method (keyboard/clickwheel).
  void updateInputMethod(String method) {
    
      inputMethod = method;
    
    notifyListeners();
    saveSettings();
  }

  /// Updates the date range filter for transactions.
  void updateFilterRange(DateTimeRange? newRange) {
    
      filterRange = newRange;
    
    notifyListeners();

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
      if (!transactionsNotifier.loadedMonths.contains(yyyyMM)) {
        await transactionsNotifier.loadMonth(yyyyMM);
      }

      // Move to next month
      monthIterator = DateTime(monthIterator.year, monthIterator.month + 1);
    }
  }

  /// Updates the category list for a specific [type] (expense or income).
  void updateCategories(String type, List<String> newCategories) {
    
      if (type == 'expense') {
        expenseCategories = newCategories;
      } else if (type == 'income') {
        incomeCategories = newCategories;
      }
    
    notifyListeners();
    // Save the updated list immediately
    saveCategories();
  }

  // Filtered List Getter
  /// Returns a list of transactions filtered by the current [filterRange].
  List<Transaction> get filteredTransactions {
    if (filterRange == null) {
      return transactions;
    }
    // Filter logic: includes transactions from start date up to the end of the end date
    return transactions.where((t) {
      final isAfterStart = t.date.isAfter(
        filterRange!.start.subtract(const Duration(microseconds: 1)),
      );
      final isBeforeEnd = t.date.isBefore(
        filterRange!.end
            .add(const Duration(days: 1))
            .subtract(const Duration(microseconds: 1)),
      );
      return isAfterStart && isBeforeEnd;
    }).toList();
  }

  // --- Build Method ---
  @override
  /// Builds the main wid

  // --- Settings Modal Bottom Sheet ---
  /// Di

  /// Shows a confirmation dialog and resets all transaction data if confirmed.
  Future<void> confirmAndResetData(BuildContext context) async {
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
      await transactionsNotifier.clearAllTransactions();
      await transactionsNotifier.clearAllTransactions();
      if (true) {
        scaffoldMessengerKey.currentState?.showSnackBar(
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
  Future<void> importTransactionsFromJsonString(
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
      await transactionsNotifier.importFromDecodedList(decoded, counts);

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
        scaffoldMessengerKey.currentState?.showSnackBar(
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
  Future<void> changeDatabaseLocation(BuildContext context) async {
    try {
      final String? selectedDirectory = await getDirectoryPath();
      if (selectedDirectory == null) return; // User canceled

      // Confirm with user
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

      
        isLoading = true;
      
    notifyListeners();

      // 1. Get current paths
      // If currentDbPath is null, it's in default Hive location.
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
            if (true) {
              scaffoldMessengerKey.currentState?.showSnackBar(
                SnackBar(content: Text('Failed to copy database: $e')),
              );
            }
            loadSettingsAndData(context); // Re-open old
            return;
          }
        }
      }

      // 4. Update Prefs
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('db_path', selectedDirectory);

      // 5. Reload
      await loadSettingsAndData(context);
    } catch (e) {
      if (true) {
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text('Error changing location: $e')),
        );
        isLoading = false;
    notifyListeners();
      }
    }
  }

  /// Exports transaction data to a file in the specified [format] (json or csv).
  Future<void> exportData(BuildContext context, String format) async {
    try {
      final currentTransactions = transactions; // Get current list
      String content = '';
      String mimeType = '';
      String extension = '';

      if (format == 'json') {
        content = jsonEncode(currentTransactions.map((e) => e.toJson()).toList());
        mimeType = 'application/json';
        extension = 'json';
      } else if (format == 'csv') {
        final buffer = StringBuffer();
        // Header
        buffer.writeln('Date,Amount,Type,Category,ID');
        for (var t in currentTransactions) {
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

      if (true) {
        scaffoldMessengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('Export successful')),
        );
      }
    } catch (e) {
      if (true) {
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }
}

// --- Category Selection Screen ---
