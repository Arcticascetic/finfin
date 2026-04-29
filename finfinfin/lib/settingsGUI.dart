import 'package:flutter/material.dart';
import 'dart:io' show File;
import 'package:file_selector/file_selector.dart';

import 'models/transaction.dart';

class SettingsSheet extends StatelessWidget {
  final ThemeMode themeMode;
  final String currencySymbol;
  final List<String> expenseCategories;
  final List<String> incomeCategories;
  final List<Transaction> allTransactions; // Pass transactions for checking
  final Map<String, double>? expenseCategoryLimits;
  final Function(ThemeMode) onUpdateTheme;
  final Function(String) onUpdateCurrency;
  final Function(String, List<String>) onUpdateCategories;
  final Function(Map<String, double>)? onUpdateCategoryLimits;
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
    this.expenseCategoryLimits,
    required this.onUpdateTheme,
    required this.onUpdateCurrency,
    required this.onUpdateCategories,
    this.onUpdateCategoryLimits,
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
  final Map<String, double>? expenseCategoryLimits;
  final Function(String, List<String>) onUpdate;
  final Function(Map<String, double>)? onUpdateLimits;

  const CategoryEditor({
    super.key,
    required this.title,
    required this.type,
    required this.categories,
    required this.allTransactions,
    this.expenseCategoryLimits,
    required this.onUpdate,
    this.onUpdateLimits,
  });

  @override
  State<CategoryEditor> createState() => _CategoryEditorState();
}

class _CategoryEditorState extends State<CategoryEditor> {
  late List<String> _localCategories;
  late Map<String, double> _expenseCategoryLimits;
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _localCategories = List.from(widget.categories);
    _expenseCategoryLimits = widget.expenseCategoryLimits != null
        ? Map.from(widget.expenseCategoryLimits!)
        : {};
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

  Future<void> _setLimit(BuildContext context, String category) async {
    final controller = TextEditingController(
      text: _expenseCategoryLimits[category]?.toString() ?? '',
    );
    final limit = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Monthly Limit for $category'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            hintText: 'Enter limit (0 to remove)',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final val = double.tryParse(controller.text) ?? 0;
              Navigator.pop(ctx, val);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (limit != null) {
      setState(() {
        if (limit > 0) {
          _expenseCategoryLimits[category] = limit;
        } else {
          _expenseCategoryLimits.remove(category);
        }
      });
      widget.onUpdateLimits?.call(_expenseCategoryLimits);
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
                      // Set Limit button (expense categories only)
                      if (widget.type == 'expense' && widget.onUpdateLimits != null)
                        TextButton(
                          onPressed: () => _setLimit(context, category),
                          child: Text(
                            _expenseCategoryLimits.containsKey(category) &&
                                    _expenseCategoryLimits[category]! > 0
                                ? 'Limit: ${_expenseCategoryLimits[category]!.toStringAsFixed(2)}'
                                : 'Set Limit',
                            style: TextStyle(
                              fontSize: 12,
                              color: _expenseCategoryLimits.containsKey(category) &&
                                      _expenseCategoryLimits[category]! > 0
                                  ? Colors.orange
                                  : null,
                            ),
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