import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/l10n/app_localizations.dart';
import 'package:sure_mobile/models/transaction.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/widgets/receipt_details_section.dart';

void main() {
  Future<void> pump(WidgetTester tester, TransactionReceipt? receipt) => tester.pumpWidget(MaterialApp(
        theme: SureTheme.light,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(body: ReceiptDetailsSection(receipt: receipt)),
      ));

  testWidgets('lists items, review reasons and the status', (tester) async {
    await pump(
      tester,
      TransactionReceipt(
        status: 'needs_review',
        reviewReasons: const ['items_total_mismatch'],
        lineItems: const [ReceiptLineItem(name: 'Cheese', amount: '30.00', categoryName: 'Food & Drink')],
      ),
    );

    expect(find.text('Receipt'), findsOneWidget);
    expect(find.text('Needs review'), findsOneWidget);
    expect(find.text('Items total mismatch'), findsOneWidget);
    expect(find.text('Cheese'), findsOneWidget);
    expect(find.text('Food & Drink'), findsOneWidget);
    expect(find.text('30.00'), findsOneWidget);
  });

  testWidgets('renders nothing without a receipt', (tester) async {
    await pump(tester, null);

    expect(find.text('Receipt'), findsNothing);
  });
}
