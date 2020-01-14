// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/services/correction/dart/abstract_producer.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_dart.dart';
import 'package:analyzer_plugin/utilities/range_factory.dart';

class ConvertToListLiteral extends CorrectionProducer {
  @override
  Future<void> compute(DartChangeBuilder builder) async {
    //
    // Ensure that this is the default constructor defined on `List`.
    //
    var creation = node.thisOrAncestorOfType<InstanceCreationExpression>();
    if (creation == null ||
        node.offset > creation.argumentList.offset ||
        creation.staticType.element != typeProvider.listElement ||
        creation.constructorName.name != null ||
        creation.argumentList.arguments.isNotEmpty) {
      return;
    }
    //
    // Extract the information needed to build the edit.
    //
    TypeArgumentList constructorTypeArguments =
        creation.constructorName.type.typeArguments;
    //
    // Build the edit.
    //
    await builder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addReplacement(range.node(creation), (DartEditBuilder builder) {
        if (constructorTypeArguments != null) {
          builder.write(utils.getNodeText(constructorTypeArguments));
        }
        builder.write('[]');
      });
    });
  }
}
