// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart2js.js_model.strategy;

import 'package:kernel/ast.dart' as ir;

import '../backend_strategy.dart';
import '../closure.dart';
import '../common.dart';
import '../common/codegen.dart' show CodegenRegistry, CodegenWorkItem;
import '../common/tasks.dart';
import '../common_elements.dart';
import '../compiler.dart';
import '../constants/constant_system.dart';
import '../constants/values.dart';
import '../deferred_load.dart';
import '../diagnostics/diagnostic_listener.dart';
import '../elements/entities.dart';
import '../elements/names.dart';
import '../elements/types.dart';
import '../elements/entity_utils.dart' as utils;
import '../environment.dart';
import '../enqueue.dart';
import '../io/kernel_source_information.dart'
    show KernelSourceInformationStrategy;
import '../io/source_information.dart';
import '../inferrer/type_graph_inferrer.dart';
import '../js_emitter/sorter.dart';
import '../js/js_source_mapping.dart';
import '../js_backend/annotations.dart';
import '../js_backend/allocator_analysis.dart';
import '../js_backend/backend.dart';
import '../js_backend/backend_usage.dart';
import '../js_backend/constant_system_javascript.dart';
import '../js_backend/inferred_data.dart';
import '../js_backend/interceptor_data.dart';
import '../js_backend/native_data.dart';
import '../js_backend/no_such_method_registry.dart';
import '../js_backend/runtime_types.dart';
import '../kernel/kernel_strategy.dart';
import '../kernel/kelements.dart';
import '../native/behavior.dart';
import '../ordered_typeset.dart';
import '../options.dart';
import '../serialization/serialization.dart';
import '../ssa/builder_kernel.dart';
import '../ssa/nodes.dart';
import '../ssa/ssa.dart';
import '../ssa/types.dart';
import '../types/abstract_value_domain.dart';
import '../types/types.dart';
import '../universe/class_hierarchy.dart';
import '../universe/class_set.dart';
import '../universe/feature.dart';
import '../universe/selector.dart';
import '../universe/world_builder.dart';
import '../universe/world_impact.dart';
import '../world.dart';
import 'closure.dart';
import 'elements.dart';
import 'element_map.dart';
import 'element_map_impl.dart';
import 'locals.dart';

class JsBackendStrategy implements BackendStrategy {
  final Compiler _compiler;
  JsKernelToElementMap _elementMap;

  JsBackendStrategy(this._compiler);

  @deprecated
  JsToElementMap get elementMap {
    assert(_elementMap != null,
        "JsBackendStrategy.elementMap has not been created yet.");
    return _elementMap;
  }

  ElementEnvironment get _elementEnvironment => _elementMap.elementEnvironment;
  CommonElements get _commonElements => _elementMap.commonElements;

  @override
  JClosedWorld createJClosedWorld(
      KClosedWorld closedWorld, OutputUnitData outputUnitData) {
    KernelFrontEndStrategy strategy = _compiler.frontendStrategy;
    _elementMap = new JsKernelToElementMap(
        _compiler.reporter,
        _compiler.environment,
        strategy.elementMap,
        closedWorld.processedMembers);
    GlobalLocalsMap _globalLocalsMap = new GlobalLocalsMap();
    ClosureDataBuilder closureDataBuilder = new ClosureDataBuilder(
        _elementMap, _globalLocalsMap, _compiler.options);
    JsClosedWorldBuilder closedWorldBuilder = new JsClosedWorldBuilder(
        _elementMap,
        _globalLocalsMap,
        closureDataBuilder,
        _compiler.options,
        _compiler.abstractValueStrategy);
    return closedWorldBuilder._convertClosedWorld(
        closedWorld, strategy.closureModels, outputUnitData);
  }

  @override
  void registerJClosedWorld(covariant JsClosedWorld closedWorld) {
    _elementMap = closedWorld.elementMap;
  }

  @override
  SourceInformationStrategy get sourceInformationStrategy {
    if (!_compiler.options.generateSourceMap) {
      return const JavaScriptSourceInformationStrategy();
    }
    return new KernelSourceInformationStrategy(this);
  }

  @override
  SsaBuilder createSsaBuilder(CompilerTask task, JavaScriptBackend backend,
      SourceInformationStrategy sourceInformationStrategy) {
    return new KernelSsaBuilder(task, backend.compiler, elementMap);
  }

  @override
  WorkItemBuilder createCodegenWorkItemBuilder(JClosedWorld closedWorld,
      GlobalTypeInferenceResults globalInferenceResults) {
    return new KernelCodegenWorkItemBuilder(
        _compiler.backend, closedWorld, globalInferenceResults);
  }

  @override
  CodegenWorldBuilder createCodegenWorldBuilder(
      NativeBasicData nativeBasicData,
      covariant JsClosedWorld closedWorld,
      SelectorConstraintsStrategy selectorConstraintsStrategy) {
    return new CodegenWorldBuilderImpl(
        closedWorld.elementMap, closedWorld, selectorConstraintsStrategy);
  }

  @override
  SourceSpan spanFromSpannable(Spannable spannable, Entity currentElement) {
    return _elementMap.getSourceSpan(spannable, currentElement);
  }

  @override
  TypesInferrer createTypesInferrer(
      JClosedWorld closedWorld, InferredDataBuilder inferredDataBuilder) {
    return new TypeGraphInferrer(_compiler, closedWorld, inferredDataBuilder);
  }
}

class JsClosedWorldBuilder {
  final JsKernelToElementMap _elementMap;
  final Map<ClassEntity, ClassHierarchyNode> _classHierarchyNodes =
      new ClassHierarchyNodesMap();
  final Map<ClassEntity, ClassSet> _classSets = <ClassEntity, ClassSet>{};
  final GlobalLocalsMap _globalLocalsMap;
  final ClosureDataBuilder _closureDataBuilder;
  final CompilerOptions _options;
  final AbstractValueStrategy _abstractValueStrategy;

  JsClosedWorldBuilder(this._elementMap, this._globalLocalsMap,
      this._closureDataBuilder, this._options, this._abstractValueStrategy);

  ElementEnvironment get _elementEnvironment => _elementMap.elementEnvironment;
  CommonElements get _commonElements => _elementMap.commonElements;

  JsClosedWorld _convertClosedWorld(
      KClosedWorld closedWorld,
      Map<MemberEntity, ScopeModel> closureModels,
      OutputUnitData kOutputUnitData) {
    JsToFrontendMap map = new JsToFrontendMapImpl(_elementMap);

    BackendUsage backendUsage =
        _convertBackendUsage(map, closedWorld.backendUsage);
    NativeData nativeData = _convertNativeData(map, closedWorld.nativeData);
    _elementMap.nativeBasicData = nativeData;
    InterceptorData interceptorData =
        _convertInterceptorData(map, nativeData, closedWorld.interceptorData);

    Set<ClassEntity> implementedClasses = new Set<ClassEntity>();

    /// Converts [node] from the frontend world to the corresponding
    /// [ClassHierarchyNode] for the backend world.
    ClassHierarchyNode convertClassHierarchyNode(ClassHierarchyNode node) {
      ClassEntity cls = map.toBackendClass(node.cls);
      if (closedWorld.isImplemented(node.cls)) {
        implementedClasses.add(cls);
      }
      ClassHierarchyNode newNode = _classHierarchyNodes.putIfAbsent(cls, () {
        ClassHierarchyNode parentNode;
        if (node.parentNode != null) {
          parentNode = convertClassHierarchyNode(node.parentNode);
        }
        return new ClassHierarchyNode(parentNode, cls, node.hierarchyDepth);
      });
      newNode.isAbstractlyInstantiated = node.isAbstractlyInstantiated;
      newNode.isDirectlyInstantiated = node.isDirectlyInstantiated;
      return newNode;
    }

    /// Converts [classSet] from the frontend world to the corresponding
    /// [ClassSet] for the backend world.
    ClassSet convertClassSet(ClassSet classSet) {
      ClassEntity cls = map.toBackendClass(classSet.cls);
      return _classSets.putIfAbsent(cls, () {
        ClassHierarchyNode newNode = convertClassHierarchyNode(classSet.node);
        ClassSet newClassSet = new ClassSet(newNode);
        for (ClassHierarchyNode subtype in classSet.subtypeNodes) {
          ClassHierarchyNode newSubtype = convertClassHierarchyNode(subtype);
          newClassSet.addSubtype(newSubtype);
        }
        return newClassSet;
      });
    }

    closedWorld.classHierarchy
        .getClassHierarchyNode(closedWorld.commonElements.objectClass)
        .forEachSubclass((ClassEntity cls) {
      convertClassSet(closedWorld.classHierarchy.getClassSet(cls));
    }, ClassHierarchyNode.ALL);

    Set<MemberEntity> liveInstanceMembers =
        map.toBackendMemberSet(closedWorld.liveInstanceMembers);

    Map<ClassEntity, Set<ClassEntity>> mixinUses =
        map.toBackendClassMap(closedWorld.mixinUses, map.toBackendClassSet);

    Map<ClassEntity, Set<ClassEntity>> typesImplementedBySubclasses =
        map.toBackendClassMap(
            closedWorld.typesImplementedBySubclasses, map.toBackendClassSet);

    Set<MemberEntity> assignedInstanceMembers =
        map.toBackendMemberSet(closedWorld.assignedInstanceMembers);

    Set<ClassEntity> liveNativeClasses =
        map.toBackendClassSet(closedWorld.liveNativeClasses);

    Set<MemberEntity> processedMembers =
        map.toBackendMemberSet(closedWorld.processedMembers);

    RuntimeTypesNeed rtiNeed;

    List<FunctionEntity> callMethods = <FunctionEntity>[];
    ClosureData closureData;
    if (_options.disableRtiOptimization) {
      rtiNeed = new TrivialRuntimeTypesNeed();
      closureData = _closureDataBuilder.createClosureEntities(
          this,
          map.toBackendMemberMap(closureModels, identity),
          const TrivialClosureRtiNeed(),
          callMethods);
    } else {
      RuntimeTypesNeedImpl kernelRtiNeed = closedWorld.rtiNeed;
      Set<ir.Node> localFunctionsNodesNeedingSignature = new Set<ir.Node>();
      for (KLocalFunction localFunction
          in kernelRtiNeed.localFunctionsNeedingSignature) {
        ir.Node node = localFunction.node;
        assert(node is ir.FunctionDeclaration || node is ir.FunctionExpression,
            "Unexpected local function node: $node");
        localFunctionsNodesNeedingSignature.add(node);
      }
      Set<ir.Node> localFunctionsNodesNeedingTypeArguments = new Set<ir.Node>();
      for (KLocalFunction localFunction
          in kernelRtiNeed.localFunctionsNeedingTypeArguments) {
        ir.Node node = localFunction.node;
        assert(node is ir.FunctionDeclaration || node is ir.FunctionExpression,
            "Unexpected local function node: $node");
        localFunctionsNodesNeedingTypeArguments.add(node);
      }

      RuntimeTypesNeedImpl jRtiNeed =
          _convertRuntimeTypesNeed(map, backendUsage, kernelRtiNeed);
      closureData = _closureDataBuilder.createClosureEntities(
          this,
          map.toBackendMemberMap(closureModels, identity),
          new JsClosureRtiNeed(
              jRtiNeed,
              localFunctionsNodesNeedingTypeArguments,
              localFunctionsNodesNeedingSignature),
          callMethods);

      List<FunctionEntity> callMethodsNeedingSignature = <FunctionEntity>[];
      for (ir.Node node in localFunctionsNodesNeedingSignature) {
        callMethodsNeedingSignature
            .add(closureData.getClosureInfo(node).callMethod);
      }
      List<FunctionEntity> callMethodsNeedingTypeArguments = <FunctionEntity>[];
      for (ir.Node node in localFunctionsNodesNeedingTypeArguments) {
        callMethodsNeedingTypeArguments
            .add(closureData.getClosureInfo(node).callMethod);
      }
      jRtiNeed.methodsNeedingSignature.addAll(callMethodsNeedingSignature);
      jRtiNeed.methodsNeedingTypeArguments
          .addAll(callMethodsNeedingTypeArguments);

      rtiNeed = jRtiNeed;
    }

    NoSuchMethodDataImpl oldNoSuchMethodData = closedWorld.noSuchMethodData;
    NoSuchMethodData noSuchMethodData = new NoSuchMethodDataImpl(
        map.toBackendFunctionSet(oldNoSuchMethodData.throwingImpls),
        map.toBackendFunctionSet(oldNoSuchMethodData.otherImpls),
        map.toBackendFunctionSet(oldNoSuchMethodData.forwardingSyntaxImpls));

    JAllocatorAnalysis allocatorAnalysis =
        JAllocatorAnalysis.from(closedWorld.allocatorAnalysis, map, _options);

    AnnotationsData annotationsData = new AnnotationsDataImpl(
        map.toBackendFunctionSet(
            closedWorld.annotationsData.nonInlinableFunctions),
        map.toBackendFunctionSet(
            closedWorld.annotationsData.tryInlineFunctions),
        map.toBackendFunctionSet(
            closedWorld.annotationsData.cannotThrowFunctions),
        map.toBackendFunctionSet(
            closedWorld.annotationsData.sideEffectFreeFunctions),
        map.toBackendMemberSet(
            closedWorld.annotationsData.trustTypeAnnotationsMembers),
        map.toBackendMemberSet(
            closedWorld.annotationsData.assumeDynamicMembers));

    OutputUnitData outputUnitData =
        _convertOutputUnitData(map, kOutputUnitData, closureData);

    return new JsClosedWorld(_elementMap,
        backendUsage: backendUsage,
        noSuchMethodData: noSuchMethodData,
        nativeData: nativeData,
        interceptorData: interceptorData,
        rtiNeed: rtiNeed,
        classHierarchy: new ClassHierarchyImpl(
            _elementMap.commonElements, _classHierarchyNodes, _classSets),
        implementedClasses: implementedClasses,
        liveNativeClasses: liveNativeClasses,
        // TODO(johnniwinther): Include the call method when we can also
        // represent the synthesized call methods for static and instance method
        // closurizations.
        liveInstanceMembers: liveInstanceMembers /*..addAll(callMethods)*/,
        assignedInstanceMembers: assignedInstanceMembers,
        processedMembers: processedMembers,
        mixinUses: mixinUses,
        typesImplementedBySubclasses: typesImplementedBySubclasses,
        abstractValueStrategy: _abstractValueStrategy,
        allocatorAnalysis: allocatorAnalysis,
        annotationsData: annotationsData,
        globalLocalsMap: _globalLocalsMap,
        closureDataLookup: closureData,
        outputUnitData: outputUnitData);
  }

  BackendUsage _convertBackendUsage(
      JsToFrontendMap map, BackendUsageImpl backendUsage) {
    Set<FunctionEntity> globalFunctionDependencies =
        map.toBackendFunctionSet(backendUsage.globalFunctionDependencies);
    Set<ClassEntity> globalClassDependencies =
        map.toBackendClassSet(backendUsage.globalClassDependencies);
    Set<FunctionEntity> helperFunctionsUsed =
        map.toBackendFunctionSet(backendUsage.helperFunctionsUsed);
    Set<ClassEntity> helperClassesUsed =
        map.toBackendClassSet(backendUsage.helperClassesUsed);
    Set<RuntimeTypeUse> runtimeTypeUses =
        backendUsage.runtimeTypeUses.map((RuntimeTypeUse runtimeTypeUse) {
      return new RuntimeTypeUse(
          runtimeTypeUse.kind,
          map.toBackendType(runtimeTypeUse.receiverType),
          map.toBackendType(runtimeTypeUse.argumentType));
    }).toSet();

    return new BackendUsageImpl(
        globalFunctionDependencies: globalFunctionDependencies,
        globalClassDependencies: globalClassDependencies,
        helperFunctionsUsed: helperFunctionsUsed,
        helperClassesUsed: helperClassesUsed,
        needToInitializeIsolateAffinityTag:
            backendUsage.needToInitializeIsolateAffinityTag,
        needToInitializeDispatchProperty:
            backendUsage.needToInitializeDispatchProperty,
        requiresPreamble: backendUsage.requiresPreamble,
        runtimeTypeUses: runtimeTypeUses,
        isFunctionApplyUsed: backendUsage.isFunctionApplyUsed,
        isMirrorsUsed: backendUsage.isMirrorsUsed,
        isNoSuchMethodUsed: backendUsage.isNoSuchMethodUsed);
  }

  NativeBasicData _convertNativeBasicData(
      JsToFrontendMap map, NativeBasicDataImpl nativeBasicData) {
    Map<ClassEntity, NativeClassTag> nativeClassTagInfo =
        <ClassEntity, NativeClassTag>{};
    nativeBasicData.nativeClassTagInfo
        .forEach((ClassEntity cls, NativeClassTag tag) {
      nativeClassTagInfo[map.toBackendClass(cls)] = tag;
    });
    Map<LibraryEntity, String> jsInteropLibraries =
        map.toBackendLibraryMap(nativeBasicData.jsInteropLibraries, identity);
    Map<ClassEntity, String> jsInteropClasses =
        map.toBackendClassMap(nativeBasicData.jsInteropClasses, identity);
    Set<ClassEntity> anonymousJsInteropClasses =
        map.toBackendClassSet(nativeBasicData.anonymousJsInteropClasses);
    Map<MemberEntity, String> jsInteropMembers =
        map.toBackendMemberMap(nativeBasicData.jsInteropMembers, identity);
    return new NativeBasicDataImpl(
        _elementEnvironment,
        nativeClassTagInfo,
        jsInteropLibraries,
        jsInteropClasses,
        anonymousJsInteropClasses,
        jsInteropMembers);
  }

  NativeData _convertNativeData(
      JsToFrontendMap map, NativeDataImpl nativeData) {
    convertNativeBehaviorType(type) {
      if (type is DartType) return map.toBackendType(type);
      assert(type is SpecialType);
      return type;
    }

    NativeBehavior convertNativeBehavior(NativeBehavior behavior) {
      NativeBehavior newBehavior = new NativeBehavior();

      for (dynamic type in behavior.typesReturned) {
        newBehavior.typesReturned.add(convertNativeBehaviorType(type));
      }
      for (dynamic type in behavior.typesInstantiated) {
        newBehavior.typesInstantiated.add(convertNativeBehaviorType(type));
      }

      newBehavior.codeTemplateText = behavior.codeTemplateText;
      newBehavior.codeTemplate = behavior.codeTemplate;
      newBehavior.throwBehavior = behavior.throwBehavior;
      newBehavior.isAllocation = behavior.isAllocation;
      newBehavior.useGvn = behavior.useGvn;
      return newBehavior;
    }

    NativeBasicData nativeBasicData = _convertNativeBasicData(map, nativeData);

    Map<MemberEntity, String> nativeMemberName =
        map.toBackendMemberMap(nativeData.nativeMemberName, identity);
    Map<FunctionEntity, NativeBehavior> nativeMethodBehavior =
        <FunctionEntity, NativeBehavior>{};
    nativeData.nativeMethodBehavior
        .forEach((FunctionEntity method, NativeBehavior behavior) {
      FunctionEntity backendMethod = map.toBackendMember(method);
      if (backendMethod != null) {
        // If [method] isn't used it doesn't have a corresponding backend
        // method.
        nativeMethodBehavior[backendMethod] = convertNativeBehavior(behavior);
      }
    });
    Map<MemberEntity, NativeBehavior> nativeFieldLoadBehavior =
        map.toBackendMemberMap(
            nativeData.nativeFieldLoadBehavior, convertNativeBehavior);
    Map<MemberEntity, NativeBehavior> nativeFieldStoreBehavior =
        map.toBackendMemberMap(
            nativeData.nativeFieldStoreBehavior, convertNativeBehavior);
    Map<LibraryEntity, String> jsInteropLibraryNames =
        map.toBackendLibraryMap(nativeData.jsInteropLibraries, identity);
    Set<ClassEntity> anonymousJsInteropClasses =
        map.toBackendClassSet(nativeData.anonymousJsInteropClasses);
    Map<ClassEntity, String> jsInteropClassNames =
        map.toBackendClassMap(nativeData.jsInteropClasses, identity);
    Map<MemberEntity, String> jsInteropMemberNames =
        map.toBackendMemberMap(nativeData.jsInteropMembers, identity);

    return new NativeDataImpl(
        nativeBasicData,
        nativeMemberName,
        nativeMethodBehavior,
        nativeFieldLoadBehavior,
        nativeFieldStoreBehavior,
        jsInteropLibraryNames,
        anonymousJsInteropClasses,
        jsInteropClassNames,
        jsInteropMemberNames);
  }

  InterceptorData _convertInterceptorData(JsToFrontendMap map,
      NativeData nativeData, InterceptorDataImpl interceptorData) {
    Map<String, Set<MemberEntity>> interceptedMembers =
        <String, Set<MemberEntity>>{};
    interceptorData.interceptedMembers
        .forEach((String name, Set<MemberEntity> members) {
      interceptedMembers[name] = map.toBackendMemberSet(members);
    });
    return new InterceptorDataImpl(
        nativeData,
        _commonElements,
        interceptedMembers,
        map.toBackendClassSet(interceptorData.interceptedClasses),
        map.toBackendClassSet(
            interceptorData.classesMixedIntoInterceptedClasses));
  }

  RuntimeTypesNeed _convertRuntimeTypesNeed(JsToFrontendMap map,
      BackendUsage backendUsage, RuntimeTypesNeedImpl rtiNeed) {
    Set<ClassEntity> classesNeedingTypeArguments =
        map.toBackendClassSet(rtiNeed.classesNeedingTypeArguments);
    Set<FunctionEntity> methodsNeedingTypeArguments =
        map.toBackendFunctionSet(rtiNeed.methodsNeedingTypeArguments);
    Set<FunctionEntity> methodsNeedingSignature =
        map.toBackendFunctionSet(rtiNeed.methodsNeedingSignature);
    Set<Selector> selectorsNeedingTypeArguments =
        rtiNeed.selectorsNeedingTypeArguments.map((Selector selector) {
      if (selector.memberName.isPrivate) {
        return new Selector(
            selector.kind,
            new PrivateName(selector.memberName.text,
                map.toBackendLibrary(selector.memberName.library),
                isSetter: selector.memberName.isSetter),
            selector.callStructure);
      }
      return selector;
    }).toSet();
    return new RuntimeTypesNeedImpl(
        _elementEnvironment,
        classesNeedingTypeArguments,
        methodsNeedingSignature,
        methodsNeedingTypeArguments,
        null,
        null,
        selectorsNeedingTypeArguments,
        rtiNeed.instantiationsNeedingTypeArguments);
  }

  /// Construct a closure class and set up the necessary class inference
  /// hierarchy.
  KernelClosureClassInfo buildClosureClass(
      MemberEntity member,
      ir.FunctionNode originalClosureFunctionNode,
      JLibrary enclosingLibrary,
      Map<Local, JRecordField> boxedVariables,
      KernelScopeInfo info,
      KernelToLocalsMap localsMap,
      {bool createSignatureMethod}) {
    ClassEntity superclass = _commonElements.closureClass;

    KernelClosureClassInfo closureClassInfo = _elementMap.constructClosureClass(
        member,
        originalClosureFunctionNode,
        enclosingLibrary,
        boxedVariables,
        info,
        localsMap,
        new InterfaceType(superclass, const []),
        createSignatureMethod: createSignatureMethod);

    // Tell the hierarchy that this is the super class. then we can use
    // .getSupertypes(class)
    ClassHierarchyNode parentNode = _classHierarchyNodes[superclass];
    ClassHierarchyNode node = new ClassHierarchyNode(parentNode,
        closureClassInfo.closureClassEntity, parentNode.hierarchyDepth + 1);
    _classHierarchyNodes[closureClassInfo.closureClassEntity] = node;
    _classSets[closureClassInfo.closureClassEntity] = new ClassSet(node);
    node.isDirectlyInstantiated = true;

    return closureClassInfo;
  }

  OutputUnitData _convertOutputUnitData(JsToFrontendMapImpl map,
      OutputUnitData data, ClosureData closureDataLookup) {
    Entity toBackendEntity(Entity entity) {
      if (entity is ClassEntity) return map.toBackendClass(entity);
      if (entity is MemberEntity) return map.toBackendMember(entity);
      if (entity is TypedefEntity) return map.toBackendTypedef(entity);
      if (entity is TypeVariableEntity) {
        return map.toBackendTypeVariable(entity);
      }
      assert(
          entity is LibraryEntity, 'unexpected entity ${entity.runtimeType}');
      return map.toBackendLibrary(entity);
    }

    // Convert front-end maps containing K-class and K-local function keys to a
    // backend map using J-classes as keys.
    Map<ClassEntity, OutputUnit> convertClassMap(
        Map<ClassEntity, OutputUnit> classMap,
        Map<Local, OutputUnit> localFunctionMap) {
      var result = <ClassEntity, OutputUnit>{};
      classMap.forEach((ClassEntity entity, OutputUnit unit) {
        ClassEntity backendEntity = toBackendEntity(entity);
        if (backendEntity != null) {
          // If [entity] isn't used it doesn't have a corresponding backend
          // entity.
          result[backendEntity] = unit;
        }
      });
      localFunctionMap.forEach((Local entity, OutputUnit unit) {
        // Ensure closure classes are included in the output unit corresponding
        // to the local function.
        if (entity is KLocalFunction) {
          var closureInfo = closureDataLookup.getClosureInfo(entity.node);
          result[closureInfo.closureClassEntity] = unit;
        }
      });
      return result;
    }

    // Convert front-end maps containing K-member and K-local function keys to
    // a backend map using J-members as keys.
    Map<MemberEntity, OutputUnit> convertMemberMap(
        Map<MemberEntity, OutputUnit> memberMap,
        Map<Local, OutputUnit> localFunctionMap) {
      var result = <MemberEntity, OutputUnit>{};
      memberMap.forEach((MemberEntity entity, OutputUnit unit) {
        MemberEntity backendEntity = toBackendEntity(entity);
        if (backendEntity != null) {
          // If [entity] isn't used it doesn't have a corresponding backend
          // entity.
          result[backendEntity] = unit;
        }
      });
      localFunctionMap.forEach((Local entity, OutputUnit unit) {
        // Ensure closure call-methods are included in the output unit
        // corresponding to the local function.
        if (entity is KLocalFunction) {
          var closureInfo = closureDataLookup.getClosureInfo(entity.node);
          result[closureInfo.callMethod] = unit;
        }
      });
      return result;
    }

    ConstantValue toBackendConstant(ConstantValue constant) {
      return constant.accept(new ConstantConverter(toBackendEntity), null);
    }

    return new OutputUnitData.from(
        data,
        map.toBackendLibrary,
        convertClassMap,
        convertMemberMap,
        (m) => convertMap<ConstantValue, OutputUnit>(
            m, toBackendConstant, (v) => v));
  }
}

class JsClosedWorld extends ClosedWorldBase {
  static const String tag = 'closed-world';

  final JsKernelToElementMap elementMap;
  final RuntimeTypesNeed rtiNeed;
  AbstractValueDomain _abstractValueDomain;
  final JAllocatorAnalysis allocatorAnalysis;
  final AnnotationsData annotationsData;
  final GlobalLocalsMap globalLocalsMap;
  final ClosureData closureDataLookup;
  final OutputUnitData outputUnitData;
  Sorter _sorter;

  JsClosedWorld(this.elementMap,
      {ConstantSystem constantSystem,
      NativeData nativeData,
      InterceptorData interceptorData,
      BackendUsage backendUsage,
      this.rtiNeed,
      this.allocatorAnalysis,
      NoSuchMethodData noSuchMethodData,
      Set<ClassEntity> implementedClasses,
      Set<ClassEntity> liveNativeClasses,
      Set<MemberEntity> liveInstanceMembers,
      Set<MemberEntity> assignedInstanceMembers,
      Set<MemberEntity> processedMembers,
      Map<ClassEntity, Set<ClassEntity>> mixinUses,
      Map<ClassEntity, Set<ClassEntity>> typesImplementedBySubclasses,
      ClassHierarchy classHierarchy,
      AbstractValueStrategy abstractValueStrategy,
      this.annotationsData,
      this.globalLocalsMap,
      this.closureDataLookup,
      this.outputUnitData})
      : super(
            elementMap.elementEnvironment,
            elementMap.types,
            elementMap.commonElements,
            JavaScriptConstantSystem.only,
            nativeData,
            interceptorData,
            backendUsage,
            noSuchMethodData,
            implementedClasses,
            liveNativeClasses,
            liveInstanceMembers,
            assignedInstanceMembers,
            processedMembers,
            mixinUses,
            typesImplementedBySubclasses,
            classHierarchy) {
    _abstractValueDomain = abstractValueStrategy.createDomain(this);
  }

  /// Deserializes a [JsClosedWorld] object from [source].
  factory JsClosedWorld.readFromDataSource(
      CompilerOptions options,
      DiagnosticReporter reporter,
      Environment environment,
      AbstractValueStrategy abstractValueStrategy,
      ir.Component component,
      DataSource source) {
    source.begin(tag);

    JsKernelToElementMap elementMap =
        new JsKernelToElementMap.readFromDataSource(
            options, reporter, environment, component, source);
    GlobalLocalsMap globalLocalsMap =
        new GlobalLocalsMap.readFromDataSource(source);
    source.registerLocalLookup(new LocalLookupImpl(globalLocalsMap));
    ClassHierarchy classHierarchy = new ClassHierarchy.readFromDataSource(
        source, elementMap.commonElements);
    NativeData nativeData = new NativeData.readFromDataSource(
        source, elementMap.elementEnvironment);
    elementMap.nativeBasicData = nativeData;
    InterceptorData interceptorData = new InterceptorData.readFromDataSource(
        source, nativeData, elementMap.commonElements);
    BackendUsage backendUsage = new BackendUsage.readFromDataSource(source);
    RuntimeTypesNeed rtiNeed = new RuntimeTypesNeed.readFromDataSource(
        source, elementMap.elementEnvironment);
    JAllocatorAnalysis allocatorAnalysis =
        new JAllocatorAnalysis.readFromDataSource(source, options);
    NoSuchMethodData noSuchMethodData =
        new NoSuchMethodData.readFromDataSource(source);

    Set<ClassEntity> implementedClasses = source.readClasses().toSet();
    Set<ClassEntity> liveNativeClasses = source.readClasses().toSet();
    Set<MemberEntity> liveInstanceMembers = source.readMembers().toSet();
    Set<MemberEntity> assignedInstanceMembers = source.readMembers().toSet();
    Set<MemberEntity> processedMembers = source.readMembers().toSet();
    Map<ClassEntity, Set<ClassEntity>> mixinUses =
        source.readClassMap(() => source.readClasses().toSet());
    Map<ClassEntity, Set<ClassEntity>> typesImplementedBySubclasses =
        source.readClassMap(() => source.readClasses().toSet());

    AnnotationsData annotationsData =
        new AnnotationsData.readFromDataSource(source);

    ClosureData closureData =
        new ClosureData.readFromDataSource(elementMap, source);

    OutputUnitData outputUnitData =
        new OutputUnitData.readFromDataSource(source);

    source.end(tag);

    return new JsClosedWorld(elementMap,
        nativeData: nativeData,
        interceptorData: interceptorData,
        backendUsage: backendUsage,
        rtiNeed: rtiNeed,
        allocatorAnalysis: allocatorAnalysis,
        noSuchMethodData: noSuchMethodData,
        implementedClasses: implementedClasses,
        liveNativeClasses: liveNativeClasses,
        liveInstanceMembers: liveInstanceMembers,
        assignedInstanceMembers: assignedInstanceMembers,
        processedMembers: processedMembers,
        mixinUses: mixinUses,
        typesImplementedBySubclasses: typesImplementedBySubclasses,
        classHierarchy: classHierarchy,
        abstractValueStrategy: abstractValueStrategy,
        annotationsData: annotationsData,
        globalLocalsMap: globalLocalsMap,
        closureDataLookup: closureData,
        outputUnitData: outputUnitData);
  }

  /// Serializes this [JsClosedWorld] to [sink].
  void writeToDataSink(DataSink sink) {
    sink.begin(tag);
    elementMap.writeToDataSink(sink);
    globalLocalsMap.writeToDataSink(sink);

    classHierarchy.writeToDataSink(sink);
    nativeData.writeToDataSink(sink);
    interceptorData.writeToDataSink(sink);
    backendUsage.writeToDataSink(sink);
    rtiNeed.writeToDataSink(sink);
    allocatorAnalysis.writeToDataSink(sink);
    noSuchMethodData.writeToDataSink(sink);
    sink.writeClasses(implementedClasses);
    sink.writeClasses(liveNativeClasses);
    sink.writeMembers(liveInstanceMembers);
    sink.writeMembers(assignedInstanceMembers);
    sink.writeMembers(processedMembers);
    sink.writeClassMap(
        mixinUses, (Set<ClassEntity> set) => sink.writeClasses(set));
    sink.writeClassMap(typesImplementedBySubclasses,
        (Set<ClassEntity> set) => sink.writeClasses(set));
    annotationsData.writeToDataSink(sink);
    closureDataLookup.writeToDataSink(sink);
    outputUnitData.writeToDataSink(sink);
    sink.end(tag);
  }

  @override
  Sorter get sorter {
    return _sorter ??= new KernelSorter(elementMap);
  }

  @override
  AbstractValueDomain get abstractValueDomain {
    return _abstractValueDomain;
  }

  @override
  bool hasElementIn(ClassEntity cls, Selector selector, Entity element) {
    while (cls != null) {
      MemberEntity member = elementEnvironment.lookupLocalClassMember(
          cls, selector.name,
          setter: selector.isSetter);
      if (member != null &&
          !member.isAbstract &&
          (!selector.memberName.isPrivate ||
              member.library == selector.library)) {
        return member == element;
      }
      cls = elementEnvironment.getSuperClass(cls);
    }
    return false;
  }

  @override
  bool hasConcreteMatch(ClassEntity cls, Selector selector,
      {ClassEntity stopAtSuperclass}) {
    assert(classHierarchy.isInstantiated(cls),
        failedAt(cls, '$cls has not been instantiated.'));
    MemberEntity element = elementEnvironment
        .lookupClassMember(cls, selector.name, setter: selector.isSetter);
    if (element == null) return false;

    if (element.isAbstract) {
      ClassEntity enclosingClass = element.enclosingClass;
      return hasConcreteMatch(
          elementEnvironment.getSuperClass(enclosingClass), selector);
    }
    return selector.appliesUntyped(element);
  }

  @override
  bool isNamedMixinApplication(ClassEntity cls) {
    return elementMap.elementEnvironment.isMixinApplication(cls) &&
        !elementMap.elementEnvironment.isUnnamedMixinApplication(cls);
  }

  @override
  ClassEntity getAppliedMixin(ClassEntity cls) {
    return elementMap.getAppliedMixin(cls);
  }

  @override
  Iterable<ClassEntity> getInterfaces(ClassEntity cls) {
    return elementMap.getInterfaces(cls).map((t) => t.element);
  }

  @override
  ClassEntity getSuperClass(ClassEntity cls) {
    return elementMap.getSuperType(cls)?.element;
  }

  @override
  int getHierarchyDepth(ClassEntity cls) {
    return elementMap.getHierarchyDepth(cls);
  }

  @override
  OrderedTypeSet getOrderedTypeSet(ClassEntity cls) {
    return elementMap.getOrderedTypeSet(cls);
  }
}

class ConstantConverter implements ConstantValueVisitor<ConstantValue, Null> {
  final Entity Function(Entity) toBackendEntity;
  final TypeConverter typeConverter;

  ConstantConverter(this.toBackendEntity)
      : typeConverter = new TypeConverter(toBackendEntity);

  ConstantValue visitNull(NullConstantValue constant, _) => constant;
  ConstantValue visitInt(IntConstantValue constant, _) => constant;
  ConstantValue visitDouble(DoubleConstantValue constant, _) => constant;
  ConstantValue visitBool(BoolConstantValue constant, _) => constant;
  ConstantValue visitString(StringConstantValue constant, _) => constant;
  ConstantValue visitSynthetic(SyntheticConstantValue constant, _) => constant;
  ConstantValue visitNonConstant(NonConstantValue constant, _) => constant;

  ConstantValue visitFunction(FunctionConstantValue constant, _) {
    return new FunctionConstantValue(
        toBackendEntity(constant.element), typeConverter.visit(constant.type));
  }

  ConstantValue visitList(ListConstantValue constant, _) {
    DartType type = typeConverter.visit(constant.type);
    List<ConstantValue> entries = _handleValues(constant.entries);
    if (identical(entries, constant.entries) && type == constant.type) {
      return constant;
    }
    return new ListConstantValue(type, entries);
  }

  ConstantValue visitMap(MapConstantValue constant, _) {
    var type = typeConverter.visit(constant.type);
    List<ConstantValue> keys = _handleValues(constant.keys);
    List<ConstantValue> values = _handleValues(constant.values);
    if (identical(keys, constant.keys) &&
        identical(values, constant.values) &&
        type == constant.type) {
      return constant;
    }
    return new MapConstantValue(type, keys, values);
  }

  ConstantValue visitConstructed(ConstructedConstantValue constant, _) {
    DartType type = typeConverter.visit(constant.type);
    Map<FieldEntity, ConstantValue> fields = {};
    constant.fields.forEach((f, v) {
      FieldEntity backendField = toBackendEntity(f);
      assert(backendField != null, "No backend field for $f.");
      fields[backendField] = v.accept(this, null);
    });
    return new ConstructedConstantValue(type, fields);
  }

  ConstantValue visitType(TypeConstantValue constant, _) {
    DartType type = typeConverter.visit(constant.type);
    DartType representedType = typeConverter.visit(constant.representedType);
    if (type == constant.type && representedType == constant.representedType) {
      return constant;
    }
    return new TypeConstantValue(representedType, type);
  }

  ConstantValue visitInterceptor(InterceptorConstantValue constant, _) {
    // Interceptor constants are only created in the SSA graph builder.
    throw new UnsupportedError(
        "Unexpected visitInterceptor ${constant.toStructuredText()}");
  }

  ConstantValue visitDeferredGlobal(DeferredGlobalConstantValue constant, _) {
    // Deferred global constants are only created in the SSA graph builder.
    throw new UnsupportedError(
        "Unexpected DeferredGlobalConstantValue ${constant.toStructuredText()}");
  }

  ConstantValue visitInstantiation(InstantiationConstantValue constant, _) {
    ConstantValue function = constant.function.accept(this, null);
    List<DartType> typeArguments =
        typeConverter.convertTypes(constant.typeArguments);
    return new InstantiationConstantValue(typeArguments, function);
  }

  List<ConstantValue> _handleValues(List<ConstantValue> values) {
    List<ConstantValue> result;
    for (int i = 0; i < values.length; i++) {
      var value = values[i];
      var newValue = value.accept(this, null);
      if (newValue != value && result == null) {
        result = values.sublist(0, i).toList();
      }
      result?.add(newValue);
    }
    return result ?? values;
  }
}

class TypeConverter implements DartTypeVisitor<DartType, Null> {
  final Entity Function(Entity) toBackendEntity;

  TypeConverter(this.toBackendEntity);

  Map<FunctionTypeVariable, FunctionTypeVariable> _functionTypeVariables =
      <FunctionTypeVariable, FunctionTypeVariable>{};

  DartType visit(DartType type, [_]) => type.accept(this, null);

  List<DartType> convertTypes(List<DartType> types) => _visitList(types);

  DartType visitVoidType(VoidType type, _) => type;
  DartType visitDynamicType(DynamicType type, _) => type;

  DartType visitTypeVariableType(TypeVariableType type, _) {
    return new TypeVariableType(toBackendEntity(type.element));
  }

  DartType visitFunctionTypeVariable(FunctionTypeVariable type, _) {
    DartType result = _functionTypeVariables[type];
    assert(result != null,
        "Function type variable $type not found in $_functionTypeVariables");
    return result;
  }

  DartType visitFunctionType(FunctionType type, _) {
    List<FunctionTypeVariable> typeVariables = <FunctionTypeVariable>[];
    for (FunctionTypeVariable typeVariable in type.typeVariables) {
      typeVariables.add(_functionTypeVariables[typeVariable] =
          new FunctionTypeVariable(typeVariable.index));
    }
    for (FunctionTypeVariable typeVariable in type.typeVariables) {
      _functionTypeVariables[typeVariable].bound =
          typeVariable.bound?.accept(this, null);
    }
    DartType returnType = type.returnType.accept(this, null);
    List<DartType> parameterTypes = _visitList(type.parameterTypes);
    List<DartType> optionalParameterTypes =
        _visitList(type.optionalParameterTypes);
    List<DartType> namedParameterTypes = _visitList(type.namedParameterTypes);
    for (FunctionTypeVariable typeVariable in type.typeVariables) {
      _functionTypeVariables.remove(typeVariable);
    }
    return new FunctionType(returnType, parameterTypes, optionalParameterTypes,
        type.namedParameters, namedParameterTypes, typeVariables);
  }

  DartType visitInterfaceType(InterfaceType type, _) {
    ClassEntity element = toBackendEntity(type.element);
    List<DartType> args = _visitList(type.typeArguments);
    return new InterfaceType(element, args);
  }

  DartType visitTypedefType(TypedefType type, _) {
    TypedefEntity element = toBackendEntity(type.element);
    List<DartType> args = _visitList(type.typeArguments);
    DartType unaliased = visit(type.unaliased);
    return new TypedefType(element, args, unaliased);
  }

  @override
  DartType visitFutureOrType(FutureOrType type, _) {
    return new FutureOrType(visit(type.typeArgument));
  }

  List<DartType> _visitList(List<DartType> list) =>
      list.map<DartType>((t) => t.accept(this, null)).toList();
}

class TrivialClosureRtiNeed implements ClosureRtiNeed {
  const TrivialClosureRtiNeed();

  @override
  bool localFunctionNeedsSignature(ir.Node node) => true;

  @override
  bool classNeedsTypeArguments(ClassEntity cls) => true;

  @override
  bool methodNeedsTypeArguments(FunctionEntity method) => true;

  @override
  bool localFunctionNeedsTypeArguments(ir.Node node) => true;

  @override
  bool selectorNeedsTypeArguments(Selector selector) => true;

  @override
  bool methodNeedsSignature(MemberEntity method) => true;

  @override
  bool instantiationNeedsTypeArguments(
          DartType functionType, int typeArgumentCount) =>
      true;
}

class JsClosureRtiNeed implements ClosureRtiNeed {
  final RuntimeTypesNeed rtiNeed;
  final Set<ir.Node> localFunctionsNodesNeedingTypeArguments;
  final Set<ir.Node> localFunctionsNodesNeedingSignature;

  JsClosureRtiNeed(this.rtiNeed, this.localFunctionsNodesNeedingTypeArguments,
      this.localFunctionsNodesNeedingSignature);

  @override
  bool localFunctionNeedsSignature(ir.Node node) {
    assert(node is ir.FunctionDeclaration || node is ir.FunctionExpression);
    return localFunctionsNodesNeedingSignature.contains(node);
  }

  @override
  bool classNeedsTypeArguments(ClassEntity cls) =>
      rtiNeed.classNeedsTypeArguments(cls);

  @override
  bool methodNeedsTypeArguments(FunctionEntity method) =>
      rtiNeed.methodNeedsTypeArguments(method);

  @override
  bool localFunctionNeedsTypeArguments(ir.Node node) {
    assert(node is ir.FunctionDeclaration || node is ir.FunctionExpression);
    return localFunctionsNodesNeedingTypeArguments.contains(node);
  }

  @override
  bool selectorNeedsTypeArguments(Selector selector) =>
      rtiNeed.selectorNeedsTypeArguments(selector);

  @override
  bool methodNeedsSignature(MemberEntity method) =>
      rtiNeed.methodNeedsSignature(method);

  @override
  bool instantiationNeedsTypeArguments(
          DartType functionType, int typeArgumentCount) =>
      rtiNeed.instantiationNeedsTypeArguments(functionType, typeArgumentCount);
}

class KernelCodegenWorkItemBuilder implements WorkItemBuilder {
  final JavaScriptBackend _backend;
  final JClosedWorld _closedWorld;
  final GlobalTypeInferenceResults _globalInferenceResults;

  KernelCodegenWorkItemBuilder(
      this._backend, this._closedWorld, this._globalInferenceResults);

  CompilerOptions get _options => _backend.compiler.options;

  @override
  CodegenWorkItem createWorkItem(MemberEntity entity) {
    if (entity.isAbstract) return null;

    // Codegen inlines field initializers. It only needs to generate
    // code for checked setters.
    if (entity.isField && entity.isInstanceMember) {
      if (!_options.parameterCheckPolicy.isEmitted ||
          entity.enclosingClass.isClosure) {
        return null;
      }
    }

    return new KernelCodegenWorkItem(
        _backend, _closedWorld, _globalInferenceResults, entity);
  }
}

class KernelCodegenWorkItem extends CodegenWorkItem {
  final JavaScriptBackend _backend;
  final JClosedWorld _closedWorld;
  final MemberEntity element;
  final CodegenRegistry registry;
  final GlobalTypeInferenceResults _globalInferenceResults;

  KernelCodegenWorkItem(this._backend, this._closedWorld,
      this._globalInferenceResults, this.element)
      : registry =
            new CodegenRegistry(_closedWorld.elementEnvironment, element);

  @override
  WorldImpact run() {
    return _backend.codegen(this, _closedWorld, _globalInferenceResults);
  }
}

/// Task for building SSA from kernel IR loaded from .dill.
class KernelSsaBuilder implements SsaBuilder {
  final CompilerTask task;
  final Compiler _compiler;
  final JsToElementMap _elementMap;
  FunctionInlineCache _inlineCache;

  KernelSsaBuilder(this.task, this._compiler, this._elementMap);

  @override
  HGraph build(CodegenWorkItem work, JClosedWorld closedWorld,
      GlobalTypeInferenceResults results) {
    _inlineCache ??= new FunctionInlineCache(closedWorld.annotationsData);
    return task.measure(() {
      KernelSsaGraphBuilder builder = new KernelSsaGraphBuilder(
          work.element,
          _elementMap.getMemberThisType(work.element),
          _compiler,
          _elementMap,
          results,
          closedWorld,
          _compiler.codegenWorldBuilder,
          work.registry,
          _compiler.backend.emitter.nativeEmitter,
          _compiler.backend.sourceInformationStrategy,
          _inlineCache);
      return builder.build();
    });
  }
}

class KernelToTypeInferenceMapImpl implements KernelToTypeInferenceMap {
  final GlobalTypeInferenceResults _globalInferenceResults;
  GlobalTypeInferenceMemberResult _targetResults;

  KernelToTypeInferenceMapImpl(
      MemberEntity target, this._globalInferenceResults) {
    _targetResults = _resultOf(target);
  }

  GlobalTypeInferenceMemberResult _resultOf(MemberEntity e) =>
      _globalInferenceResults
          .resultOfMember(e is ConstructorBodyEntity ? e.constructor : e);

  AbstractValue getReturnTypeOf(FunctionEntity function) {
    return AbstractValueFactory.inferredReturnTypeForElement(
        function, _globalInferenceResults);
  }

  AbstractValue receiverTypeOfInvocation(
      ir.MethodInvocation node, AbstractValueDomain abstractValueDomain) {
    return _targetResults.typeOfSend(node);
  }

  AbstractValue receiverTypeOfGet(ir.PropertyGet node) {
    return _targetResults.typeOfSend(node);
  }

  AbstractValue receiverTypeOfDirectGet(ir.DirectPropertyGet node) {
    return _targetResults.typeOfSend(node);
  }

  AbstractValue receiverTypeOfSet(
      ir.PropertySet node, AbstractValueDomain abstractValueDomain) {
    return _targetResults.typeOfSend(node);
  }

  AbstractValue typeOfListLiteral(
      ir.ListLiteral listLiteral, AbstractValueDomain abstractValueDomain) {
    return _globalInferenceResults.typeOfListLiteral(listLiteral) ??
        abstractValueDomain.dynamicType;
  }

  AbstractValue typeOfIterator(ir.ForInStatement node) {
    return _targetResults.typeOfIterator(node);
  }

  AbstractValue typeOfIteratorCurrent(ir.ForInStatement node) {
    return _targetResults.typeOfIteratorCurrent(node);
  }

  AbstractValue typeOfIteratorMoveNext(ir.ForInStatement node) {
    return _targetResults.typeOfIteratorMoveNext(node);
  }

  bool isJsIndexableIterator(
      ir.ForInStatement node, AbstractValueDomain abstractValueDomain) {
    AbstractValue mask = typeOfIterator(node);
    return abstractValueDomain.isJsIndexableAndIterable(mask);
  }

  AbstractValue inferredIndexType(ir.ForInStatement node) {
    return AbstractValueFactory.inferredTypeForSelector(
        new Selector.index(), typeOfIterator(node), _globalInferenceResults);
  }

  AbstractValue getInferredTypeOf(MemberEntity member) {
    return AbstractValueFactory.inferredTypeForMember(
        member, _globalInferenceResults);
  }

  AbstractValue getInferredTypeOfParameter(Local parameter) {
    return AbstractValueFactory.inferredTypeForParameter(
        parameter, _globalInferenceResults);
  }

  AbstractValue selectorTypeOf(Selector selector, AbstractValue mask) {
    return AbstractValueFactory.inferredTypeForSelector(
        selector, mask, _globalInferenceResults);
  }

  AbstractValue typeFromNativeBehavior(
      NativeBehavior nativeBehavior, JClosedWorld closedWorld) {
    return AbstractValueFactory.fromNativeBehavior(nativeBehavior, closedWorld);
  }
}

class KernelSorter implements Sorter {
  final JsToElementMap elementMap;

  KernelSorter(this.elementMap);

  int _compareLibraries(LibraryEntity a, LibraryEntity b) {
    return utils.compareLibrariesUris(a.canonicalUri, b.canonicalUri);
  }

  int _compareSourceSpans(Entity entity1, SourceSpan sourceSpan1,
      Entity entity2, SourceSpan sourceSpan2) {
    int r = utils.compareSourceUris(sourceSpan1.uri, sourceSpan2.uri);
    if (r != 0) return r;
    return utils.compareEntities(
        entity1, sourceSpan1.begin, null, entity2, sourceSpan2.begin, null);
  }

  @override
  Iterable<LibraryEntity> sortLibraries(Iterable<LibraryEntity> libraries) {
    return libraries.toList()..sort(_compareLibraries);
  }

  @override
  Iterable<T> sortMembers<T extends MemberEntity>(Iterable<T> members) {
    return members.toList()..sort(compareMembersByLocation);
  }

  @override
  Iterable<ClassEntity> sortClasses(Iterable<ClassEntity> classes) {
    List<ClassEntity> regularClasses = <ClassEntity>[];
    List<ClassEntity> unnamedMixins = <ClassEntity>[];
    for (ClassEntity cls in classes) {
      if (elementMap.elementEnvironment.isUnnamedMixinApplication(cls)) {
        unnamedMixins.add(cls);
      } else {
        regularClasses.add(cls);
      }
    }
    List<ClassEntity> sorted = <ClassEntity>[];
    regularClasses.sort(compareClassesByLocation);
    sorted.addAll(regularClasses);
    unnamedMixins.sort((a, b) {
      int result = _compareLibraries(a.library, b.library);
      if (result != 0) return result;
      result = a.name.compareTo(b.name);
      assert(result != 0,
          failedAt(a, "Multiple mixins named ${a.name}: $a vs $b."));
      return result;
    });
    sorted.addAll(unnamedMixins);
    return sorted;
  }

  @override
  Iterable<TypedefEntity> sortTypedefs(Iterable<TypedefEntity> typedefs) {
    // TODO(redemption): Support this.
    assert(typedefs.isEmpty);
    return typedefs;
  }

  @override
  int compareLibrariesByLocation(LibraryEntity a, LibraryEntity b) {
    return _compareLibraries(a, b);
  }

  @override
  int compareClassesByLocation(ClassEntity a, ClassEntity b) {
    int r = _compareLibraries(a.library, b.library);
    if (r != 0) return r;
    ClassDefinition definition1 = elementMap.getClassDefinition(a);
    ClassDefinition definition2 = elementMap.getClassDefinition(b);
    return _compareSourceSpans(
        a, definition1.location, b, definition2.location);
  }

  @override
  int compareTypedefsByLocation(TypedefEntity a, TypedefEntity b) {
    // TODO(redemption): Support this.
    failedAt(a, 'KernelSorter.compareTypedefsByLocation unimplemented');
    return 0;
  }

  @override
  int compareMembersByLocation(MemberEntity a, MemberEntity b) {
    int r = _compareLibraries(a.library, b.library);
    if (r != 0) return r;
    MemberDefinition definition1 = elementMap.getMemberDefinition(a);
    MemberDefinition definition2 = elementMap.getMemberDefinition(b);
    return _compareSourceSpans(
        a, definition1.location, b, definition2.location);
  }
}

/// [LocalLookup] implementation used to deserialize [JsClosedWorld].
class LocalLookupImpl implements LocalLookup {
  final GlobalLocalsMap _globalLocalsMap;

  LocalLookupImpl(this._globalLocalsMap);

  @override
  Local getLocalByIndex(MemberEntity memberContext, int index) {
    KernelToLocalsMapImpl map = _globalLocalsMap.getLocalsMap(memberContext);
    return map.getLocalByIndex(index);
  }
}
