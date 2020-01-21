// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/src/dart/analysis/experiments.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'driver_resolution.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(PostfixExpressionResolutionTest);
    defineReflectiveTests(PostfixExpressionResolutionWithNnbdTest);
  });
}

@reflectiveTest
class PostfixExpressionResolutionTest extends DriverResolutionTest {
  test_dec_localVariable() async {
    await assertNoErrorsInCode(r'''
f(int x) {
  x--;
}
''');

    assertPostfixExpression(
      findNode.postfix('x--'),
      element: numElement.getMethod('-'),
      type: 'int',
    );
  }

  test_inc_localVariable() async {
    await assertNoErrorsInCode(r'''
f(int x) {
  x++;
}
''');

    assertPostfixExpression(
      findNode.postfix('x++'),
      element: numElement.getMethod('+'),
      type: 'int',
    );
  }

  test_inc_property_differentTypes() async {
    await assertNoErrorsInCode(r'''
dynamic get x => 0;

set x(Object _) {}

f() {
  x++;
}
''');

    assertSimpleIdentifier(
      findNode.simple('x++'),
      element: findElement.topSet('x'),
      type: 'Object',
    );

    assertPostfixExpression(
      findNode.postfix('x++'),
      element: null,
      type: 'dynamic',
    );
  }
}

@reflectiveTest
class PostfixExpressionResolutionWithNnbdTest
    extends PostfixExpressionResolutionTest {
  @override
  AnalysisOptionsImpl get analysisOptions =>
      AnalysisOptionsImpl()..enabledExperiments = [EnableString.non_nullable];

  @override
  bool get typeToStringWithNullability => true;

  test_inc_localVariable_depromote() async {
    await assertNoErrorsInCode(r'''
class A {
  Object operator +(int _) => this;
}

f(Object x) {
  if (x is A) {
    x++;
    x; // ref
  }
}
''');

    assertType(findNode.simple('x++;'), 'A');

    assertPostfixExpression(
      findNode.postfix('x++'),
      element: findElement.method('+'),
      type: 'A',
    );

    assertType(findNode.simple('x; // ref'), 'Object');
  }

  test_nullCheck() async {
    await assertNoErrorsInCode(r'''
f(int? x) {
  x!;
}
''');

    assertPostfixExpression(
      findNode.postfix('x!'),
      element: null,
      type: 'int',
    );
  }

  test_nullCheck_functionExpressionInvocation_rewrite() async {
    await assertNoErrorsInCode(r'''
main(Function f2) {
  f2(42)!;
}
''');
  }

  test_nullCheck_null() async {
    await assertNoErrorsInCode('''
main(Null x) {
  x!;
}
''');

    assertType(findNode.postfix('x!'), 'Never');
  }

  test_nullCheck_nullableContext() async {
    await assertNoErrorsInCode(r'''
T f<T>(T t) => t;

int g() => f(null)!;
''');

    assertMethodInvocation2(
      findNode.methodInvocation('f(null)'),
      element: findElement.topFunction('f'),
      typeArgumentTypes: ['int?'],
      invokeType: 'int? Function(int?)',
      type: 'int?',
    );

    assertPostfixExpression(
      findNode.postfix('f(null)!'),
      element: null,
      type: 'int',
    );
  }

  test_nullCheck_typeParameter() async {
    await assertNoErrorsInCode(r'''
f<T>(T? x) {
  x!;
}
''');

    assertPostfixExpression(
      findNode.postfix('x!'),
      element: null,
      type: 'T',
    );
  }
}
