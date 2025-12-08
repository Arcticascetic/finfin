import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:hive/hive.dart';
import 'transaction.dart'; // Transaction model

/// Lightweight ChangeNotifier that owns the transactions list and
/// handles persistence to Hive using individual keys (ID -> JSON).
class TransactionsNotifier extends ChangeNotifier {
  final Box _box;

  TransactionsNotifier(this._box);

  List<Transaction> _transactions = [];

  List<Transaction> get transactions => List.unmodifiable(_transactions);

  bool get isEmpty => _transactions.isEmpty;

  Future<void> loadFromHive() async {
    _transactions = [];
    // 1. Migration from legacy 'transactions' list key
    if (_box.containsKey('transactions')) {
      final stored = _box.get('transactions');
      if (stored is List) {
        for (var s in stored) {
          try {
            // handle both map and string formats if necessary, but old code saved list of strings
            final String jsonStr = s is String ? s : json.encode(s);
            final map = json.decode(jsonStr) as Map<String, dynamic>;
            final t = Transaction.fromJson(map);

            // Save individually
            // await _box.put(t.id, json.encode(t.toJson())); // Optimized below
            _transactions.add(t);
            // dirty = true; // Handled by bulk put below
          } catch (_) {
            // skip corrupted
          }
        }

        // Optimisation: Bulk write all migrated transactions
        if (_transactions.isNotEmpty) {
          final Map<String, String> batch = {
            for (var t in _transactions) t.id: json.encode(t.toJson()),
          };
          await _box.putAll(batch);
        }
      }
      // Delete the legacy key
      await _box.delete('transactions');
    }

    // 2. Load individual values
    // Iterate keys ensuring we don't pick up metadata/garbage (though we expect this box to be clean)
    for (var key in _box.keys) {
      if (key == 'transactions')
        continue; // Should be deleted above, but just in case

      final val = _box.get(key);
      if (val is String) {
        try {
          final map = json.decode(val) as Map<String, dynamic>;
          final t = Transaction.fromJson(map);
          // Avoid duplicates if migration just happened (though we cleared _transactions)
          if (!_transactions.any((tx) => tx.id == t.id)) {
            _transactions.add(t);
          }
        } catch (_) {}
      }
    }

    _transactions.sort((a, b) => a.date.compareTo(b.date));
    notifyListeners();
  }

  /// Bulk add transactions (optimized)
  Future<void> addTransactions(List<Transaction> txns) async {
    _transactions.addAll(txns);
    _transactions.sort((a, b) => a.date.compareTo(b.date));
    notifyListeners();

    final Map<String, String> batch = {
      for (var t in txns) t.id: json.encode(t.toJson()),
    };
    await _box.putAll(batch);
  }

  Future<void> addTransaction(Transaction t) async {
    _transactions.add(t);
    _transactions.sort((a, b) => a.date.compareTo(b.date));
    notifyListeners();
    // Persist individually
    await _box.put(t.id, json.encode(t.toJson()));
  }

  Future<void> removeTransaction(Transaction t) async {
    _transactions.removeWhere((tx) => tx.id == t.id);
    notifyListeners();
    await _box.delete(t.id);
  }

  Future<void> updateTransaction(Transaction oldT, Transaction newT) async {
    final idx = _transactions.indexWhere((tt) => tt.id == oldT.id);
    if (idx != -1) {
      _transactions[idx] = newT;
      _transactions.sort((a, b) => a.date.compareTo(b.date));
      notifyListeners();
      await _box.put(newT.id, json.encode(newT.toJson()));
    }
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
}
