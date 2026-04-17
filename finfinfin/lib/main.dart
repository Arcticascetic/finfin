import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'logic.dart';
import 'gui.dart';

void main() async {
  Intl.defaultLocale = 'en_US';
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  
  final logic = AppLogic();
  
  runApp(
    MaterialApp(debugShowCheckedModeBanner: false, home: BudgetApp(logic: logic)),
  );
}
