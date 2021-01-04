// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/kernel.dart';
import 'package:kernel/target/targets.dart';
import 'package:kernel/core_types.dart';
import 'package:meta/meta.dart';
import 'package:vm/transformations/type_flow/transformer.dart' as globalTypeFlow
    show transformComponent;
import 'package:vm/transformations/no_dynamic_invocations_annotator.dart'
    show Selector;

class TransformationInfo {
  final List<String> removedMessageFields = <String>[];
  final List<Class> removedMessageClasses = <Class>[];
}

TransformationInfo transformComponent(
    Component component, Map<String, String> environment, Target target,
    {@required bool collectInfo}) {
  final coreTypes = new CoreTypes(component);

  TransformationInfo info = collectInfo ? TransformationInfo() : null;

  _treeshakeProtos(target, component, coreTypes, info);
  return info;
}

void _treeshakeProtos(Target target, Component component, CoreTypes coreTypes,
    TransformationInfo info) {
  globalTypeFlow.transformComponent(target, coreTypes, component,
      treeShakeSignatures: false);

  final collector = removeUnusedProtoReferences(component, coreTypes, info);
  if (collector != null) {
    globalTypeFlow.transformComponent(target, coreTypes, component,
        treeShakeSignatures: false);
    if (info != null) {
      for (Class gmSubclass in collector.gmSubclasses) {
        if (!gmSubclass.enclosingLibrary.classes.contains(gmSubclass)) {
          info.removedMessageClasses.add(gmSubclass);
        }
      }
    }
  }

  // Remove metadata added by the typeflow analysis (even if the code doesn't
  // use any protos).
  component.metadata.clear();
}

/// Called by the signature shaker to exclude the positional parameters of
/// certain members whose first few parameters are depended upon by the
/// protobuf-aware tree shaker.
bool excludePositionalParametersFromSignatureShaking(Member member) {
  return member.enclosingClass?.name == 'BuilderInfo' &&
      member.enclosingLibrary.importUri ==
          Uri.parse('package:protobuf/protobuf.dart') &&
      _UnusedFieldMetadataPruner.fieldAddingMethods.contains(member.name.name);
}

InfoCollector removeUnusedProtoReferences(
    Component component, CoreTypes coreTypes, TransformationInfo info) {
  final protobufUri = Uri.parse('package:protobuf/protobuf.dart');
  final protobufLibs =
      component.libraries.where((lib) => lib.importUri == protobufUri);
  if (protobufLibs.isEmpty) {
    return null;
  }
  final protobufLib = protobufLibs.single;

  final gmClass = protobufLib.classes
      .where((klass) => klass.name == 'GeneratedMessage')
      .single;
  final tagNumberClass =
      protobufLib.classes.where((klass) => klass.name == 'TagNumber').single;

  final collector = InfoCollector(gmClass);

  final biClass =
      protobufLib.classes.where((klass) => klass.name == 'BuilderInfo').single;
  final addMethod =
      biClass.members.singleWhere((Member member) => member.name.text == 'add');

  component.accept(collector);

  _UnusedFieldMetadataPruner(tagNumberClass, biClass, addMethod,
          collector.dynamicSelectors, coreTypes, info)
      .removeMetadataForUnusedFields(
    collector.gmSubclasses,
    collector.gmSubclassesInvokedMethods,
    coreTypes,
    info,
  );

  return collector;
}

/// For protobuf fields which are not accessed, prune away its metadata.
class _UnusedFieldMetadataPruner extends TreeVisitor<void> {
  final Class tagNumberClass;
  final Reference tagNumberField;
  // All of those methods have the dart field name as second positional
  // parameter.
  // Method names are defined in:
  // https://github.com/dart-lang/protobuf/blob/master/protobuf/lib/src/protobuf/builder_info.dart
  // The code is generated by:
  // https://github.com/dart-lang/protobuf/blob/master/protoc_plugin/lib/protobuf_field.dart.
  static final fieldAddingMethods = Set<String>.from(const <String>[
    'a',
    'aOM',
    'aOS',
    'aQM',
    'pPS',
    'aQS',
    'aInt64',
    'aOB',
    'e',
    'p',
    'pc',
    'm',
  ]);

  final Class builderInfoClass;
  Class visitedClass;
  final names = Set<String>();
  final usedTagNumbers = Set<int>();

  final dynamicNames = Set<String>();
  final CoreTypes coreTypes;
  final TransformationInfo info;
  final Member addMethod;

  _UnusedFieldMetadataPruner(this.tagNumberClass, this.builderInfoClass,
      this.addMethod, Set<Selector> dynamicSelectors, this.coreTypes, this.info)
      : tagNumberField = tagNumberClass.fields
            .firstWhere((f) => f.name.text == 'tagNumber')
            .getterReference {
    dynamicNames.addAll(dynamicSelectors.map((sel) => sel.target.text));
  }

  /// If a proto message field is never accessed (neither read nor written to),
  /// remove its corresponding metadata in the construction of the Message._i
  /// field (i.e. the BuilderInfo metadata).
  void removeMetadataForUnusedFields(
      Set<Class> gmSubclasses,
      Map<Class, Set<Selector>> invokedMethods,
      CoreTypes coreTypes,
      TransformationInfo info) {
    for (final klass in gmSubclasses) {
      final selectors = invokedMethods[klass] ?? Set<Selector>();
      final builderInfoFields = klass.fields.where((f) => f.name.text == '_i');
      if (builderInfoFields.isEmpty) {
        continue;
      }
      final builderInfoField = builderInfoFields.single;
      _pruneBuilderInfoField(builderInfoField, selectors, klass);
    }
  }

  void _pruneBuilderInfoField(
      Field field, Set<Selector> selectors, Class gmSubclass) {
    names.clear();
    names.addAll(selectors.map((sel) => sel.target.text));
    visitedClass = gmSubclass;
    _computeUsedTagNumbers(gmSubclass);
    field.initializer.accept(this);
  }

  void _computeUsedTagNumbers(Class gmSubclass) {
    usedTagNumbers.clear();
    for (final procedure in gmSubclass.procedures) {
      for (final annotation in procedure.annotations) {
        if (annotation is ConstantExpression) {
          final constant = annotation.constant;
          if (constant is InstanceConstant &&
              constant.classReference == tagNumberClass.reference) {
            final name = procedure.name.text;
            if (dynamicNames.contains(name) || names.contains(name)) {
              usedTagNumbers.add(
                  (constant.fieldValues[tagNumberField] as IntConstant).value);
            }
          }
        }
      }
    }
  }

  @override
  visitBlockExpression(BlockExpression node) {
    // The BuilderInfo field `_i` is set up with a row of cascaded calls.
    // ```
    // static final BuilderInfo _i = BuilderInfo('MessageName')
    //     ..a(1, 'foo', PbFieldType.OM)
    //     ..a(2, 'bar', PbFieldType.OM)
    // ```
    // Each cascaded call will be represented in kernel as an entry in a
    // BlockExpression (but starts out in a Let), where each statement in block
    // is an ExpressionStatement, and where each statement will be a call to a
    // method of `builderInfo`.
    // For example:
    // ```
    // {protobuf::BuilderInfo::a}<dart.core::int*>(1, "foo", #C10)
    // ```
    // The methods enumerated in `fieldAddingMethods` are the ones that set up
    // fields (other methods do other things).
    //
    // First argument is the tag-number of the added field.
    // Second argument is the field-name.
    // Further arguments are specific to the method.
    for (Statement statement in node.body.statements) {
      if (statement is ExpressionStatement) {
        _changeCascadeEntry(statement.expression);
      }
    }
    node.body.accept(this);
  }

  @override
  visitLet(Let node) {
    // See comment in visitBlockExpression.
    node.body.accept(this);
  }

  String _extractFieldName(Expression expression) {
    if (expression is StringLiteral) {
      return expression.value;
    }
    if (expression is ConditionalExpression) {
      return _extractFieldName(expression.otherwise);
    }
    throw ArgumentError.value(
        expression, 'expression', 'Unsupported  expression');
  }

  void _changeCascadeEntry(Expression initializer) {
    if (initializer is MethodInvocation &&
        initializer.interfaceTarget?.enclosingClass == builderInfoClass &&
        fieldAddingMethods.contains(initializer.name.text)) {
      final tagNumber =
          (initializer.arguments.positional[0] as IntLiteral).value;
      if (!usedTagNumbers.contains(tagNumber)) {
        if (info != null) {
          final fieldName =
              _extractFieldName(initializer.arguments.positional[1]);
          info.removedMessageFields.add("${visitedClass.name}.$fieldName");
        }

        // Replace the field metadata method with a dummy call to
        // `BuilderInfo.add`. This is to preserve the index calculations when
        // removing a field.
        // Change the tag-number to 0. Otherwise the decoder will get confused.
        initializer.interfaceTarget = addMethod;
        initializer.name = addMethod.name;
        initializer.arguments.replaceWith(
          Arguments(
            <Expression>[
              IntLiteral(0), // tagNumber
              NullLiteral(), // name
              NullLiteral(), // fieldType
              NullLiteral(), // defaultOrMaker
              NullLiteral(), // subBuilder
              NullLiteral(), // valueOf
              NullLiteral(), // enumValues
            ],
            types: <DartType>[const NullType()],
          ),
        );
      }
    }
  }
}

/// Finds all subclasses of [GeneratedMessage] and all methods invoked on them
/// (potentially in a dynamic call).
class InfoCollector extends RecursiveVisitor<void> {
  final dynamicSelectors = Set<Selector>();
  final Class generatedMessageClass;
  final gmSubclasses = Set<Class>();
  final gmSubclassesInvokedMethods = Map<Class, Set<Selector>>();

  InfoCollector(this.generatedMessageClass);

  @override
  visitClass(Class klass) {
    if (isGeneratedMethodSubclass(klass)) {
      gmSubclasses.add(klass);
    }
    return super.visitClass(klass);
  }

  @override
  visitMethodInvocation(MethodInvocation node) {
    if (node.interfaceTarget == null) {
      dynamicSelectors.add(Selector.doInvoke(node.name));
    }

    final targetClass = node.interfaceTarget?.enclosingClass;
    if (isGeneratedMethodSubclass(targetClass)) {
      addInvokedMethod(targetClass, Selector.doInvoke(node.name));
    }
    super.visitMethodInvocation(node);
  }

  @override
  visitPropertyGet(PropertyGet node) {
    if (node.interfaceTarget == null) {
      dynamicSelectors.add(Selector.doGet(node.name));
    }

    final targetClass = node.interfaceTarget?.enclosingClass;
    if (isGeneratedMethodSubclass(targetClass)) {
      addInvokedMethod(targetClass, Selector.doGet(node.name));
    }
    super.visitPropertyGet(node);
  }

  @override
  visitPropertySet(PropertySet node) {
    if (node.interfaceTarget == null) {
      dynamicSelectors.add(Selector.doSet(node.name));
    }

    final targetClass = node.interfaceTarget?.enclosingClass;
    if (isGeneratedMethodSubclass(targetClass)) {
      addInvokedMethod(targetClass, Selector.doSet(node.name));
    }
    super.visitPropertySet(node);
  }

  bool isGeneratedMethodSubclass(Class klass) {
    return klass?.superclass == generatedMessageClass;
  }

  void addInvokedMethod(Class klass, Selector selector) {
    final selectors =
        gmSubclassesInvokedMethods.putIfAbsent(klass, () => Set<Selector>());
    selectors.add(selector);
  }
}
