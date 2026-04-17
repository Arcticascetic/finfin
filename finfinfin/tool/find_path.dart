import 'package:flutter/widgets.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // On Linux, Hive.initFlutter uses getApplicationDocumentsDirectory (or support)
  // Let's just print the path provider result
  try {
    // Note: getApplicationDocumentsDirectory on Linux often maps to ~/Documents
    // getApplicationSupportDirectory maps to ~/.local/share/app_name

    // Hive.initFlutter() uses getApplicationDocumentsDirectory() by default if I recall correctly
    // OR it uses the current directory?
    // Actually checking source, it uses getApplicationDocumentsDirectory().

    //  final docDir = await getApplicationDocumentsDirectory();
    //  print('Documents Directory: ${docDir.path}');

    //  final supDir = await getApplicationSupportDirectory();
    //  print('Support Directory: ${supDir.path}');
  } catch (e) {
    print('Error: $e');
  }
}
