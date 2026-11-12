import 'package:easy_auth/src/widgets/verification_login_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'review email accepts the long access code while normal email keeps four digits',
    (tester) async {
      var starts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: VerificationLoginForm(
                type: VerificationType.email,
                reviewAccessEmail: 'app-review@kiku.test',
                onLoginStart: () => starts++,
              ),
            ),
          ),
        ),
      );

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'ordinary@example.test');
      await tester.enterText(fields.at(1), '123');
      await tester.tap(find.text('登录'));
      await tester.pump();
      expect(starts, 0);
      expect(find.text('验证码为4位数字'), findsOneWidget);

      await tester.enterText(fields.at(0), 'APP-REVIEW@kiku.test');
      await tester.pump();
      expect(find.text('发送验证码'), findsNothing);
      const reviewCode = 'abcdefghijklmnopqrstuvwxyz012345';
      await tester.enterText(fields.at(1), reviewCode);
      await tester.tap(find.text('登录'));
      await tester.pump();
      expect(starts, 1);
      expect(
        tester.widget<TextFormField>(fields.at(1)).controller!.text,
        reviewCode,
      );

      await tester.enterText(fields.at(0), 'ordinary@example.test');
      await tester.pump();
      await tester.enterText(fields.at(1), '1234');
      await tester.tap(find.text('登录'));
      await tester.pump();
      expect(starts, 2);
      expect(find.text('发送验证码'), findsOneWidget);
    },
  );
}
