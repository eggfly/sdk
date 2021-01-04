// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/services/correction/fix/data_driven/accessor.dart';
import 'package:analysis_server/src/services/correction/fix/data_driven/code_template.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_dart.dart';
import 'package:analyzer_plugin/utilities/range_factory.dart';

/// Use a specified argument from an invocation as the value of a template
/// variable.
class CodeFragment extends ValueGenerator {
  /// The accessor used to access the code fragment.
  final List<Accessor> accessors;

  /// Initialize a newly created extractor to extract a code fragment.
  CodeFragment(this.accessors);

  @override
  String evaluateIn(TemplateContext context) {
    Object target = context.node;
    for (var i = 0; i < accessors.length; i++) {
      var result = accessors[i].getValue(target);
      if (!result.isValid) {
        return '';
      }
      target = result.result;
    }
    if (target is AstNode) {
      return context.utils.getRangeText(range.node(target));
    } else if (target is DartType) {
      // TODO(brianwilkerson) If we end up needing it, figure out how to convert
      //  a type into valid code.
      throw UnsupportedError('Unexpected result of ${target.runtimeType}');
    } else {
      throw UnsupportedError('Unexpected result of ${target.runtimeType}');
    }
  }

  @override
  bool validate(TemplateContext context) {
    Object target = context.node;
    for (var accessor in accessors) {
      var result = accessor.getValue(target);
      if (!result.isValid) {
        return false;
      }
      target = result.result;
    }
    return true;
  }

  @override
  void writeOn(DartEditBuilder builder, TemplateContext context) {
    Object target = context.node;
    for (var accessor in accessors) {
      target = accessor.getValue(target).result;
    }
    if (target is AstNode) {
      builder.write(context.utils.getRangeText(range.node(target)));
    } else if (target is DartType) {
      builder.writeType(target);
    } else {
      throw UnsupportedError('Unexpected result of ${target.runtimeType}');
    }
  }
}

/// Use a name that might need to be imported from a different library as the
/// value of a template variable.
class ImportedName extends ValueGenerator {
  /// The URIs of the libraries from which the name can be imported.
  final List<Uri> uris;

  /// The name to be used.
  final String name;

  ImportedName(this.uris, this.name);

  @override
  String evaluateIn(TemplateContext context) {
    return name;
  }

  @override
  bool validate(TemplateContext context) {
    // TODO(brianwilkerson) Validate that the import can be added.
    return true;
  }

  @override
  void writeOn(DartEditBuilder builder, TemplateContext context) {
    builder.writeImportedName(uris, name);
  }
}

/// An object used to generate the value of a template variable.
abstract class ValueGenerator {
  /// Return the value generated by this generator, using the [context] to
  /// access needed information that isn't already known to this generator.
  String evaluateIn(TemplateContext context);

  /// Use the [context] to validate that this generator will be able to generate
  /// a value.
  bool validate(TemplateContext context);

  /// Write the value generated by this generator to the given [builder], using
  /// the [context] to access needed information that isn't already known to
  /// this generator.
  void writeOn(DartEditBuilder builder, TemplateContext context);
}
