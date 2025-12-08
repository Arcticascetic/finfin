import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:hive/hive.dart';
import 'package:intl/intl.dart'; // Required for DateFormat
import 'transaction.dart'; // Transaction model

/// Lightweight ChangeNotifier that owns the transactions list and
/// handles persistence to Hive using individual keys (ID -> JSON).
///
/// It supports lazy loading by:
/// 1. Scanning keys to identify available months (metadata).
/// 2. Loading only the current and previous month initially.
/// 3. Providing [loadMonth] to fetch older data on demand.
///
/// Keys are stored as `YYYYMM-UUID` to allow efficient prefix filtering.
class TransactionsNotifier extends ChangeNotifier {
  final Box _box;

  TransactionsNotifier(this._box);

  List<Transaction> _transactions = [];

  // Lazy Loading State
  final Set<String> _availableMonths = {};
  final Set<String> _loadedMonths = {};
  double _totalBalance = 0.0;

  double get totalBalance => _totalBalance;
  Set<String> get availableMonths => _availableMonths;
  Set<String> get loadedMonths => _loadedMonths;

  List<Transaction> get transactions => List.unmodifiable(_transactions);

  bool get isEmpty => _transactions.isEmpty;

  /// Loads keys, migrates if needed, and loads initial months (Current & Previous).
  Future<void> loadFromHive() async {
    _transactions.clear();
    _availableMonths.clear();
    _loadedMonths.clear();
    _totalBalance = 0.0;

    // 1. Scan keys to build available months and detect legacy keys
    final legacyKeys = <String>[];
    bool balanceLoaded = false;

    // We can't iterate _box.keys efficiently if it's huge, but Hive keys are in memory usually.
    for (var key in _box.keys) {
      if (key == 'transactions') continue; // Should be gone, but safety first
      if (key == 'total_balance') {
        _totalBalance = (_box.get(key) as num).toDouble();
        balanceLoaded = true;
        continue;
      }
      if (key is String) {
        // Check format: YYYYMM-UUID
        if (RegExp(r'^\d{6}-').hasMatch(key)) {
          final yyyyMM = key.substring(0, 6);
          _availableMonths.add(yyyyMM);
        } else {
          // Assume legacy UUID-only key
          legacyKeys.add(key);
        }
      }
    }

    // 2. Migration: If legacy keys exist, migrate them to YYYYMM-UUID
    if (legacyKeys.isNotEmpty) {
      // Load all legacy transactions
      final migratedTxns = <Transaction>[];
      for (var key in legacyKeys) {
        final val = _box.get(key);
        if (val is String) {
          try {
            final t = Transaction.fromJson(json.decode(val));
            migratedTxns.add(t);
          } catch (_) {}
        }
      }

      // Calculate balance from scratch since we are migrating
      _totalBalance = 0;
      for (var t in migratedTxns) {
        _totalBalance += (t.type == 'income' ? t.amount : -t.amount);
      }
      balanceLoaded = true;

      // Save using new keys
      final Map<String, String> batch = {};
      for (var t in migratedTxns) {
        final key = _generateKey(t);
        batch[key] = json.encode(t.toJson());

        final yyyyMM = key.substring(0, 6);
        _availableMonths.add(yyyyMM);
      }

      await _box.putAll(batch);
      await _box.deleteAll(legacyKeys); // Remove old keys
      await _box.put('total_balance', _totalBalance); // Save balance
    }

    if (!balanceLoaded) {
      // If no migration happened but we also didn't find a balance key (fresh start or corrupted), start at 0
      _totalBalance = 0;
      await _box.put('total_balance', 0.0);
    }

    // 3. Load Initial Months (Current & Previous)
    final now = DateTime.now();
    final currentMonth = DateFormat('yyyyMM').format(now);
    final previousMonth = DateFormat(
      'yyyyMM',
    ).format(DateTime(now.year, now.month - 1));

    await loadMonth(currentMonth);
    await loadMonth(previousMonth);
  }

  /// Loads transactions for a specific month (format yyyyMM) if not already loaded.
  Future<void> loadMonth(String yyyyMM) async {
    if (_loadedMonths.contains(yyyyMM)) return; // Already loaded

    // Find keys starting with this prefix
    // Optimisation: If we scanned keys in step 1, we could have cached them.
    // But iterating keys again is okay for lazy load as we only do it on user action.
    // Hive doesn't support prefix queries directly, so we filter keys.
    final keysToLoad = _box.keys.where(
      (k) => k is String && k.startsWith('$yyyyMM-'),
    );

    final newTxns = <Transaction>[];
    for (var key in keysToLoad) {
      final val = _box.get(key);
      if (val is String) {
        try {
          final t = Transaction.fromJson(json.decode(val));
          if (!_transactions.any((tx) => tx.id == t.id)) {
            newTxns.add(t);
          }
        } catch (_) {}
      }
    }

    if (newTxns.isNotEmpty) {
      _transactions.addAll(newTxns);
      _transactions.sort(
        (a, b) => a.date.compareTo(b.date),
      ); // Keep global list sorted
      // TODO: If we have millions of transactions, sorting the whole list on every load might be slow.
      // Consider inserting sorted or using a better data structure if this becomes a bottleneck.
      notifyListeners();
    }
    _loadedMonths.add(yyyyMM);
  }

  String _generateKey(Transaction t) {
    // Format: YYYYMM-UUID
    final yyyyMM = DateFormat('yyyyMM').format(t.date);
    return '$yyyyMM-${t.id}';
  }

  /// Bulk add transactions (optimized)
  Future<void> addTransactions(List<Transaction> txns) async {
    _transactions.addAll(txns);
    _transactions.sort((a, b) => a.date.compareTo(b.date));

    final Map<String, String> batch = {};
    for (var t in txns) {
      final key = _generateKey(t);
      batch[key] = json.encode(t.toJson());

      final yyyyMM = key.substring(0, 6);
      if (_availableMonths.add(yyyyMM)) {
        // Optionally notify that a new month is available?
      }
      _loadedMonths.add(yyyyMM); // We just loaded/added it

      _totalBalance += (t.type == 'income' ? t.amount : -t.amount);
    }

    notifyListeners();
    await _box.putAll(batch);
    await _box.put('total_balance', _totalBalance);
  }

  Future<void> addTransaction(Transaction t) async {
    _transactions.add(t);
    _transactions.sort((a, b) => a.date.compareTo(b.date));

    final key = _generateKey(t);
    final yyyyMM = key.substring(0, 6);
    _availableMonths.add(yyyyMM);
    _loadedMonths.add(yyyyMM); // Implicitly loaded since we just added it

    _totalBalance += (t.type == 'income' ? t.amount : -t.amount);

    notifyListeners();
    await _box.put(key, json.encode(t.toJson()));
    await _box.put('total_balance', _totalBalance);
  }

  Future<void> removeTransaction(Transaction t) async {
    // Use ID matching to be safe against reference mismatches
    _transactions.removeWhere((tx) => tx.id == t.id);
    _totalBalance -= (t.type == 'income' ? t.amount : -t.amount);
    notifyListeners();

    final key = _generateKey(t);
    // Find key might be tricky if date changed and we generated key from date.
    // Ideally ID should be enough but we used date in key.
    // IF the user changes the date, the key changes.
    // So we must ensure we delete the OLD key.
    // For now, assume key matches current object state.
    // If we support editing DATE, we must perform a delete-then-add or know the old ID.
    // This looks like a potential issue for updateTransaction if date changes.
    // For simple remove, it works if object is consistent with DB.

    // Attempt to delete specific key
    if (_box.containsKey(key)) {
      await _box.delete(key);
    } else {
      // Fallback: This object might have came from an old loads with just UUID as key?
      // Or the date changed?
      // If migration happened, it should have the new key.
      // Safe fallback: check if UUID exists as plain key
      if (_box.containsKey(t.id)) {
        await _box.delete(t.id);
      } else {
        // Scan for ID? Expensive but safe.
        // Let's assume consistent key for now.
      }
    }
    await _box.put('total_balance', _totalBalance);
  }

  Future<void> updateTransaction(Transaction oldTxn, Transaction newTxn) async {
    final oldKey = _generateKey(oldTxn);
    final newKey = _generateKey(newTxn);

    // Update memory
    // Use ID matching instead of reference equality (indexOf) to be safe
    final index = _transactions.indexWhere((t) => t.id == oldTxn.id);
    if (index != -1) {
      _transactions[index] = newTxn;
      _transactions.sort((a, b) => a.date.compareTo(b.date));
    }

    // Update balance
    double oldVal = (oldTxn.type == 'income' ? oldTxn.amount : -oldTxn.amount);
    double newVal = (newTxn.type == 'income' ? newTxn.amount : -newTxn.amount);
    _totalBalance += (newVal - oldVal);

    notifyListeners();

    // Update Hive
    if (oldKey != newKey) {
      // Date changed (or ID, but ID shouldn't change)
      await _box.delete(oldKey);
      // Also check fallback legacy key
      if (_box.containsKey(oldTxn.id)) await _box.delete(oldTxn.id);
    }

    await _box.put(newKey, json.encode(newTxn.toJson()));
    await _box.put('total_balance', _totalBalance);

    final yyyyMM = newKey.substring(0, 6);
    _availableMonths.add(yyyyMM);
    _loadedMonths.add(yyyyMM);
  }

  /// Bulk import. Replaces current data.
  Future<void> importFromDecodedList(
    List<dynamic> decoded,
    ValueNotifier<Map<String, int>> counts, {
    int batchSize = 512,
  }) async {
    // Clear current data first
    await _box.clear();
    _transactions = [];

    // Temporary list to hold parsed items
    final List<Transaction> parsed = [];

    counts.value = {...counts.value, 'total': decoded.length};

    int processed = 0;
    int imported = 0;
    int skipped = 0;

    for (var item in decoded) {
      Transaction? t;
      try {
        Map<String, dynamic> map;
        if (item is String) {
          map = json.decode(item) as Map<String, dynamic>;
        } else if (item is Map) {
          map = Map<String, dynamic>.from(item);
        } else {
          throw FormatException("Invalid type");
        }
        t = Transaction.fromJson(map);
      } catch (e) {
        skipped++;
        processed++;
        counts.value = {
          ...counts.value,
          'processed': processed,
          'skipped': skipped,
        };
        continue;
      }

      parsed.add(t);
      // Write to Hive individually
      await _box.put(t.id, json.encode(t.toJson()));

      imported++;
      processed++;

      // Batch update UI
      if (processed % 50 == 0) {
        counts.value = {
          ...counts.value,
          'processed': processed,
          'imported': imported,
          'skipped': skipped,
        };
        await Future<void>.delayed(Duration.zero);
      }
    }

    _transactions = parsed;
    _transactions.sort((a, b) => a.date.compareTo(b.date));
    notifyListeners();
  }

  Future<void> clearAllTransactions() async {
    // Clear everything related to transactions
    _transactions.clear();
    _availableMonths.clear();
    _loadedMonths.clear();
    _totalBalance = 0.0;

    notifyListeners();

    // Clear Hive Box completely
    await _box.clear();
    // Re-initialize metadata
    await _box.put('total_balance', 0.0);
  }
}
