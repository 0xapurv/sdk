// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/provisional/completion/dart/completion_dart.dart';
import 'package:analysis_server/src/services/completion/dart/extension_member_contributor.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'completion_contributor_util.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(ExtensionMemberContributorTest);
  });
}

@reflectiveTest
class ExtensionMemberContributorTest extends DartCompletionContributorTest {
  @override
  DartCompletionContributor createContributor() {
    return ExtensionMemberContributor();
  }

  @override
  void setUp() {
    createAnalysisOptionsFile(experiments: ['extension-methods']);
    super.setUp();
  }

  test_extension() async {
    addTestSource('''
extension E on int {}
void f() {
  E.a^
}
''');
    await computeSuggestions();
    assertNoSuggestions();
  }

  test_extensionOverride_doesNotMatch() async {
    addTestSource('''
extension E on int {
  bool a(int b, int c) {}
  int get b => 0;
  set c(int d) {}
}
void f() {
  E('3').a^
}
''');
    await computeSuggestions();
    assertSuggestMethod('a', null, 'bool', defaultArgListString: 'b, c');
    assertSuggestGetter('b', 'int');
    assertSuggestSetter('c');
  }

  test_extensionOverride_matches() async {
    addTestSource('''
extension E on int {
  bool a(int b, int c) {}
  int get b => 0;
  set c(int d) {}
}
void f() {
  E(2).a^
}
''');
    await computeSuggestions();
    assertSuggestMethod('a', null, 'bool', defaultArgListString: 'b, c');
    assertSuggestGetter('b', 'int');
    assertSuggestSetter('c');
  }

  test_function_doesNotMatch() async {
    addTestSource('''
extension E<T extends num> on List<T> {
  bool a(int b, int c) {}
  int get b => 0;
  set c(int d) {}
}
List<T> g<T>(T x) => [x];
void f(String s) {
  g(s).a^
}
''');
    await computeSuggestions();
    assertNotSuggested('a');
    assertNotSuggested('b');
    assertNotSuggested('c');
  }

  test_function_matches() async {
    addTestSource('''
extension E on int {
  bool a(int b, int c) {}
  int get b => 0;
  set c(int d) {}
}
void f() {
  g().a^
}
int g() => 3;
''');
    await computeSuggestions();
    assertSuggestMethod('a', null, 'bool', defaultArgListString: 'b, c');
    assertSuggestGetter('b', 'int');
    assertSuggestSetter('c');
  }

  test_identifier_doesNotMatch() async {
    addTestSource('''
extension E<T extends num> on List<T> {
  bool a(int b, int c) {}
  int get b => 0;
  set c(int d) {}
}
void f(List<String> l) {
  l.a^
}
''');
    await computeSuggestions();
    assertNotSuggested('a');
    assertNotSuggested('b');
    assertNotSuggested('c');
  }

  test_identifier_matches() async {
    addTestSource('''
extension E<T extends num> on List<T> {
  bool a(int b, int c) {}
  int get b => 0;
  set c(int d) {}
}
void f(List<int> l) {
  l.a^
}
''');
    await computeSuggestions();
    assertSuggestMethod('a', null, 'bool', defaultArgListString: 'b, c');
    assertSuggestGetter('b', 'int');
    assertSuggestSetter('c');
  }

  test_literal_doesNotMatch() async {
    addTestSource('''
extension E on String {
  bool a(int b, int c) {}
  int get b => 0;
  set c(int d) {}
}

void f() {
  0.^
}
''');
    await computeSuggestions();
    assertNotSuggested('a');
    assertNotSuggested('b');
    assertNotSuggested('c');
  }

  test_literal_doesNotMatch_generic() async {
    addTestSource('''
extension E<T extends num> on List<T> {
  bool a(int b, int c) {}
  int get b => 0;
  set c(int d) {}
}
void f() {
  ['a'].a^
}
''');
    await computeSuggestions();
    assertNotSuggested('a');
    assertNotSuggested('b');
    assertNotSuggested('c');
  }

  test_literal_matches() async {
    addTestSource('''
extension E on int {
  bool a(int b, int c) {}
  int get b => 0;
  set c(int d) {}
}
void f() {
  2.a^
}
''');
    await computeSuggestions();
    assertSuggestMethod('a', null, 'bool', defaultArgListString: 'b, c');
    assertSuggestGetter('b', 'int');
    assertSuggestSetter('c');
  }

  test_members_inExtendedClassMethod_getter() async {
    addTestSource('''
class Person {
  void doSomething() {
    ^
  }
}
extension E on Person {
  String get name => '';
  set id(int id) {}
  void work() { }
}
''');
    await computeSuggestions();
    assertSuggestGetter('name', 'String');
  }

  test_members_inExtendedClassMethod_method() async {
    addTestSource('''
class Person {
  void doSomething() {
    ^
  }
}
extension E on Person {
  String get name => '';
  set id(int id) {}
  void work() { }
}
''');
    await computeSuggestions();
    assertSuggestMethod('work', null, 'void');
  }

  test_members_inExtendedClassMethod_multipleExtensions() async {
    addTestSource('''
class Person {
  void doSomething() {
    ^
  }
}
extension E on Person {
  String get name => '';
}

extension E2 on Person {
  void work() { }
}

''');
    await computeSuggestions();
    assertSuggestGetter('name', 'String');
    assertSuggestMethod('work', null, 'void');
  }

  test_members_inExtendedClassMethod_setter() async {
    addTestSource('''
class Person {
  void doSomething() {
    ^
  }
}
extension E on Person {
  String get name => '';
  set id(int id) {}
  void work() { }
}
''');
    await computeSuggestions();
    assertSuggestSetter('id');
  }

  test_members_inMixinMethod_method() async {
    addTestSource('''
class Person { }
extension E on Person {
  void work() { }
}

mixin M on Person {
  void f() {
    ^
  }
}
''');
    await computeSuggestions();
    assertSuggestMethod('work', null, 'void');
  }

  test_members_with_this_inExtendedClass() async {
    addTestSource('''
class Person {
  void doSomething() {
    this.^
  }
}
extension E on Person {
  String get name => '';
  set id(int id) {}
  void work() { }
}
''');
    await computeSuggestions();
    assertSuggestSetter('id');
    assertSuggestGetter('name', 'String');
    assertSuggestMethod('work', null, 'void');
  }
}
