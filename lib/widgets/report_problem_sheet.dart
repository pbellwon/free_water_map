import 'package:flutter/material.dart';

import '../models/place_report_data.dart';

class ReportProblemSheet extends StatefulWidget {
  const ReportProblemSheet({super.key});

  @override
  State<ReportProblemSheet> createState() =>
      _ReportProblemSheetState();
}

class _ReportProblemSheetState
    extends State<ReportProblemSheet> {
  final _detailsController = TextEditingController();

  String _selectedReason = 'no_free_water';

  @override
  void dispose() {
    _detailsController.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(
      PlaceReportData(
        reason: _selectedReason,
        details: _detailsController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final keyboardHeight =
        MediaQuery.viewInsetsOf(context).bottom;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          8,
          20,
          20 + keyboardHeight,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            const Text(
              'Zgłoś problem',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Wybierz powód zgłoszenia. '
              'Lokal nie zostanie automatycznie usunięty.',
            ),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              initialValue: _selectedReason,
              decoration: const InputDecoration(
                labelText: 'Rodzaj problemu',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: 'no_free_water',
                  child: Text(
                    'Nie podają już darmowej wody',
                  ),
                ),
                DropdownMenuItem(
                  value: 'wrong_location',
                  child: Text(
                    'Błędny adres lub pozycja',
                  ),
                ),
                DropdownMenuItem(
                  value: 'closed',
                  child: Text(
                    'Lokal jest zamknięty lub nie istnieje',
                  ),
                ),
                DropdownMenuItem(
                  value: 'duplicate',
                  child: Text(
                    'To duplikat innego wpisu',
                  ),
                ),
                DropdownMenuItem(
                  value: 'other',
                  child: Text('Inny problem'),
                ),
              ],
              onChanged: (value) {
                if (value == null) {
                  return;
                }

                setState(() {
                  _selectedReason = value;
                });
              },
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _detailsController,
              maxLength: 500,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Dodatkowe informacje',
                hintText:
                    'Opcjonalnie opisz problem dokładniej.',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    vertical: 14,
                  ),
                ),
                onPressed: _submit,
                icon: const Icon(Icons.flag),
                label: const Text(
                  'Wyślij zgłoszenie',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}