import 'package:uuid/uuid.dart';

class Transaction {
  final String id;
  final double amount;
  final String type; // 'income' or 'expense'
  final String category;
  final DateTime date;

  Transaction({
    String? id,
    required this.amount,
    required this.type,
    required this.category,
    required this.date,
  }) : id = id ?? const Uuid().v4();

  Map<String, dynamic> toJson() => {
    'id': id,
    'amount': amount,
    'type': type,
    'category': category,
    'date': date.toIso8601String(),
  };

  factory Transaction.fromJson(Map<String, dynamic> json) {
    if (json['amount'] == null ||
        json['type'] == null ||
        json['category'] == null ||
        json['date'] == null) {
      throw const FormatException("Missing required field in transaction JSON");
    }
    final parsedDate = DateTime.parse(json['date'] as String).toLocal();
    return Transaction(
      id: json['id'] as String?,
      amount: (json['amount'] as num).toDouble(),
      type: json['type'] as String,
      category: json['category'] as String,
      date: parsedDate,
    );
  }
}
