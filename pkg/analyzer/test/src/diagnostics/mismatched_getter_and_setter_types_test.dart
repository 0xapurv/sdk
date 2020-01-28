// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../dart/resolution/driver_resolution.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(MismatchedGetterAndSetterTypesTest);
    defineReflectiveTests(
        MismatchedGetterAndSetterTypesWithExtensionMethodsTest);
    defineReflectiveTests(MismatchedGetterAndSetterTypesWithNNBDTest);
  });
}

@reflectiveTest
class MismatchedGetterAndSetterTypesTest extends DriverResolutionTest {
  test_class_instance_dynamicGetter() async {
    await assertNoErrorsInCode(r'''
class C {
  get x => 0;
  set x(String v) {}
}
''');
  }

  test_class_instance_dynamicSetter() async {
    await assertNoErrorsInCode(r'''
class C {
  int get x => 0;
  set x(v) {}
}
''');
  }

  test_class_instance_interfaces() async {
    await assertErrorsInCode(r'''
class A {
  int get foo => 0;
}

class B {
  set foo(String _) {}
}

abstract class X implements A, B {}
''', [
      error(StaticWarningCode.MISMATCHED_GETTER_AND_SETTER_TYPES, 84, 1),
    ]);
  }

  test_class_instance_private_getter() async {
    newFile('/test/lib/a.dart', content: r'''
class A {
  int get _foo => 0;
}
''');
    await assertErrorsInCode(r'''
import 'a.dart';

class B extends A {
  set _foo(String _) {}
}
''', [
      error(HintCode.UNUSED_ELEMENT, 44, 4),
    ]);
  }

  test_class_instance_private_interfaces() async {
    newFile('/test/lib/a.dart', content: r'''
class A {
  int get _foo => 0;
}
''');
    newFile('/test/lib/b.dart', content: r'''
class B {
  set _foo(String _) {}
}
''');
    await assertNoErrorsInCode(r'''
import 'a.dart';
import 'b.dart';

class X implements A, B {}
''');
  }

  test_class_instance_private_interfaces2() async {
    newFile('/test/lib/a.dart', content: r'''
class A {
  int get _foo => 0;
}

class B {
  set _foo(String _) {}
}
''');
    await assertNoErrorsInCode(r'''
import 'a.dart';

class X implements A, B {}
''');
  }

  test_class_instance_private_setter() async {
    newFile('/test/lib/a.dart', content: r'''
class A {
  set _foo(String _) {}
}
''');
    await assertErrorsInCode(r'''
import 'a.dart';

class B extends A {
  int get _foo => 0;
}
''', [
      error(HintCode.UNUSED_ELEMENT, 48, 4),
    ]);
  }

  test_class_instance_sameClass() async {
    await assertErrorsInCode(r'''
class C {
  int get foo => 0;
  set foo(String _) {}
}
''', [
      error(StaticWarningCode.MISMATCHED_GETTER_AND_SETTER_TYPES, 20, 3),
    ]);
  }

  test_class_instance_sameTypes() async {
    await assertNoErrorsInCode(r'''
class C {
  int get x => 0;
  set x(int v) {}
}
''');
  }

  test_class_instance_setterParameter_0() async {
    await assertErrorsInCode(r'''
class C {
  int get foo => 0;
  set foo() {}
}
''', [
      error(CompileTimeErrorCode.WRONG_NUMBER_OF_PARAMETERS_FOR_SETTER, 36, 3),
    ]);
  }

  test_class_instance_setterParameter_2() async {
    await assertErrorsInCode(r'''
class C {
  int get foo => 0;
  set foo(String p1, String p2) {}
}
''', [
      error(CompileTimeErrorCode.WRONG_NUMBER_OF_PARAMETERS_FOR_SETTER, 36, 3),
    ]);
  }

  test_class_instance_superGetter() async {
    await assertErrorsInCode(r'''
class A {
  int get foo => 0;
}

class B extends A {
  set foo(String _) {}
}
''', [
      error(StaticWarningCode.MISMATCHED_GETTER_AND_SETTER_TYPES, 59, 3),
    ]);
  }

  test_class_instance_superSetter() async {
    await assertErrorsInCode(r'''
class A {
  set foo(String _) {}
}

class B extends A {
  int get foo => 0;
}
''', [
      error(StaticWarningCode.MISMATCHED_GETTER_AND_SETTER_TYPES, 66, 3),
    ]);
  }

  test_topLevel() async {
    await assertErrorsInCode('''
int get g { return 0; }
set g(String v) {}''', [
      error(StaticWarningCode.MISMATCHED_GETTER_AND_SETTER_TYPES, 0, 23),
    ]);
  }

  test_topLevel_dynamicGetter() async {
    await assertNoErrorsInCode(r'''
get x => 0;
set x(String v) {}
''');
  }

  test_topLevel_dynamicSetter() async {
    await assertNoErrorsInCode(r'''
int get x => 0;
set x(v) {}
''');
  }

  test_topLevel_sameTypes() async {
    await assertNoErrorsInCode(r'''
int get x => 0;
set x(int v) {}
''');
  }
}

@reflectiveTest
class MismatchedGetterAndSetterTypesWithExtensionMethodsTest
    extends MismatchedGetterAndSetterTypesTest {
  @override
  AnalysisOptionsImpl get analysisOptions => AnalysisOptionsImpl()
    ..contextFeatures = FeatureSet.forTesting(
        sdkVersion: '2.3.0', additionalFeatures: [Feature.extension_methods]);

  test_extension_instance() async {
    await assertErrorsInCode('''
extension E on Object {
  int get g { return 0; }
  set g(String v) {}
}
''', [
      error(StaticWarningCode.MISMATCHED_GETTER_AND_SETTER_TYPES, 34, 1),
    ]);
  }

  test_extension_static() async {
    await assertErrorsInCode('''
extension E on Object {
  static int get g { return 0; }
  static set g(String v) {}
}
''', [
      error(StaticWarningCode.MISMATCHED_GETTER_AND_SETTER_TYPES, 41, 1),
    ]);
  }
}

@reflectiveTest
class MismatchedGetterAndSetterTypesWithNNBDTest
    extends MismatchedGetterAndSetterTypesTest {
  @override
  AnalysisOptionsImpl get analysisOptions => AnalysisOptionsImpl()
    ..contextFeatures = FeatureSet.forTesting(
        sdkVersion: '2.3.0', additionalFeatures: [Feature.non_nullable]);

  test_nullSafety_class_instance() async {
    await assertErrorsInCode('''
class C {
  num get g { return 0; }
  set g(int v) {}
}
''', [
      error(StaticWarningCode.MISMATCHED_GETTER_AND_SETTER_TYPES, 20, 1),
    ]);
  }

  @failingTest
  test_nullSafety_class_static() async {
    await assertErrorsInCode('''
class C {
  static num get g { return 0; }
  static set g(int v) {}
}
''', [
      error(StaticWarningCode.MISMATCHED_GETTER_AND_SETTER_TYPES, 12, 30),
    ]);
  }
}
