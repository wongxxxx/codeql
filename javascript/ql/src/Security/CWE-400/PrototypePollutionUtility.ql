/**
 * @name Prototype pollution in utility function
 * @description Recursively copying properties between objects may cause
                accidental modification of a built-in prototype object.
 * @kind path-problem
 * @problem.severity warning
 * @precision high
 * @id js/prototype-pollution-utility
 * @tags security
 *       external/cwe/cwe-079
 *       external/cwe/cwe-116
 */

import javascript
import DataFlow
import PathGraph
import semmle.javascript.dataflow.InferredTypes

/**
 * Gets a node that refers to an element of `array`, likely obtained
 * as a result of enumerating the elements of the array.
 */
SourceNode getAnEnumeratedArrayElement(SourceNode array) {
  exists(MethodCallNode call, string name |
    call = array.getAMethodCall(name) and
    (name = "forEach" or name = "map") and
    result = call.getCallback(0).getParameter(0)
  )
  or
  exists(DataFlow::PropRead read |
    read = array.getAPropertyRead() and
    not exists(read.getPropertyName()) and
    not read.getPropertyNameExpr().analyze().getAType() = TTString() and
    result = read
  )
}

/**
 * A data flow node that refers to the name of a property obtained by enumerating
 * the properties of some object.
 */
class EnumeratedPropName extends DataFlow::Node {
  DataFlow::Node object;

  EnumeratedPropName() {
    exists(ForInStmt stmt |
      this = DataFlow::lvalueNode(stmt.getLValue()) and
      object = stmt.getIterationDomain().flow()
    )
    or
    exists(CallNode call, string name |
      call = globalVarRef("Object").getAMemberCall(name) and
      (name = "keys" or name = "getOwnPropertyNames") and
      object = call.getArgument(0) and
      this = getAnEnumeratedArrayElement(call)
    )
  }

  /**
   * Gets the object whose properties are being enumerated.
   *
   * For example, gets `src` in `for (var key in src)`.
   */
  Node getSourceObject() { result = object }

  /**
   * Gets a local reference of the source object.
   */
  SourceNode getASourceObjectRef() {
    exists(SourceNode root, string path |
      getSourceObject() = AccessPath::getAReferenceTo(root, path) and
      result = AccessPath::getAReferenceTo(root, path)
    )
    or
    result = getSourceObject().getALocalSource()
  }

  /**
   * Gets a property read that accesses the corresponding property value in the source object.
   *
   * For example, gets `src[key]` in `for (var key in src) { src[key]; }`.
   */
  PropRead getASourceProp() {
    result = getASourceObjectRef().getAPropertyRead() and
    result.getPropertyNameExpr().flow().getImmediatePredecessor*() = this
  }
}

/**
 * Holds if the properties of `node` are enumerated locally.
 */
predicate arePropertiesEnumerated(DataFlow::SourceNode node) {
  node = any(EnumeratedPropName name).getASourceObjectRef()
}

/**
 * A dynamic property access that is not obviously an array access.
 */
class DynamicPropRead extends DataFlow::SourceNode, DataFlow::ValueNode {
  // Use IndexExpr instead of PropRead as we're not interested in implicit accesses like
  // rest-patterns and for-of loops.
  override IndexExpr astNode;

  DynamicPropRead() {
    not exists(astNode.getPropertyName()) and
    // Exclude obvious array access
    astNode.getPropertyNameExpr().analyze().getAType() = TTString()
  }

  /** Gets the base of the dynamic read. */
  DataFlow::Node getBase() { result = astNode.getBase().flow() }
}

/**
 * Holds if there is a dynamic property assignment of form `base[prop] = rhs`
 * which might act as the writing operation in a recursive merge function.
 *
 * Only assignments to pre-existing objects are of interest, so object/array literals
 * are not included.
 *
 * Additionally, we ignore cases where the properties of `base` are enumerated, as this
 * would typically not happen in a merge function.
 */
predicate dynamicPropWrite(DataFlow::Node base, DataFlow::Node prop, DataFlow::Node rhs) {
  exists(AssignExpr write, IndexExpr index |
    index = write.getLhs() and
    base = index.getBase().flow() and
    prop = index.getPropertyNameExpr().flow() and
    rhs = write.getRhs().flow() and
    not exists(prop.getStringValue()) and
    not arePropertiesEnumerated(base.getALocalSource())
  )
}

/** Gets the name of a property that can lead to `Object.prototype`. */
string unsafePropName() {
  result = "__proto__"
  or
  result = "constructor"
}

/**
 * Flow label representing an unsafe property name, or an object obtained
 * by using such a property in a dynamic read.
 */
class UnsafePropLabel extends FlowLabel {
  UnsafePropLabel() { this = unsafePropName() }
}

/**
 * Tracks data from property enumerations to dynamic property writes.
 *
 * The intent is to find code of the general form:
 * ```js
 * function merge(dst, src) {
 *   for (var key in src)
 *     if (...)
 *       merge(dst[key], src[key])
 *     else
 *       dst[key] = src[key]
 * }
 * ```
 *
 * This configuration is used to find four separate data flow paths originating
 * from a property enumeration, all leading to the same dynamic property write.
 *
 * In particular, the base, property name, and rhs of the property write should all
 * depend on the enumerated property name (`key`) and the right-hand side should
 * additionally depend on the source object (`src`), while allowing steps of form
 * `x -> x[p]` and `p -> x[p]`.
 *
 * Note that in the above example, the flow from `key` to the base of the write (`dst`)
 * requires stepping through the recursive call.
 * Such a path would be absent for a shallow copying operation.
 */
class PropNameTracking extends DataFlow::Configuration {
  PropNameTracking() { this = "PropNameTracking" }

  override predicate isSource(DataFlow::Node node, FlowLabel label) {
    label instanceof UnsafePropLabel and
    exists(EnumeratedPropName prop |
      node = prop
      or
      node = prop.getASourceProp()
    )
  }

  override predicate isSink(DataFlow::Node node, FlowLabel label) {
    label instanceof UnsafePropLabel and
    (
      dynamicPropWrite(node, _, _) or
      dynamicPropWrite(_, node, _) or
      dynamicPropWrite(_, _, node)
    )
  }

  override predicate isAdditionalFlowStep(
    DataFlow::Node pred, DataFlow::Node succ, FlowLabel predlbl, FlowLabel succlbl
  ) {
    predlbl instanceof UnsafePropLabel and
    succlbl = predlbl and
    (
      // Step through `p -> x[p]`
      exists(PropRead read |
        pred = read.getPropertyNameExpr().flow() and
        succ = read
      )
      or
      // Step through `x -> x[p]`
      exists(DynamicPropRead read |
        pred = read.getBase() and
        succ = read
      )
    )
  }

  override predicate isBarrierGuard(DataFlow::BarrierGuardNode node) {
    node instanceof EqualityGuard or
    node instanceof HasOwnPropertyGuard or
    node instanceof InstanceOfGuard or
    node instanceof TypeofGuard or
    node instanceof ArrayInclusionGuard
  }
}

/**
 * Sanitizer guard of form `x === "__proto__"` or `x === "constructor"`.
 */
class EqualityGuard extends DataFlow::LabeledBarrierGuardNode, ValueNode {
  override EqualityTest astNode;
  string propName;

  EqualityGuard() {
    astNode.getAnOperand().getStringValue() = propName and
    propName = unsafePropName()
  }

  override predicate blocks(boolean outcome, Expr e, FlowLabel label) {
    e = astNode.getAnOperand() and
    outcome = astNode.getPolarity().booleanNot() and
    label = propName
  }
}

/**
 * Sanitizer guard for calls to `Object.prototype.hasOwnProperty`.
 *
 * A malicious source object will have `__proto__` and/or `constructor` as own properties,
 * but the destination object generally doesn't. It is therefore only a sanitizer when
 * used on the destination object.
 */
class HasOwnPropertyGuard extends DataFlow::BarrierGuardNode, CallNode {
  HasOwnPropertyGuard() {
    // Make sure we handle reflective calls since libraries love to do that.
    getCalleeNode().getALocalSource().(DataFlow::PropRead).getPropertyName() = "hasOwnProperty" and
    exists(getReceiver()) and
    // Try to avoid `src.hasOwnProperty` by requiring that the receiver
    // does not locally have its properties enumerated. Typically there is no
    // reason to enumerate the properties of the destination object.
    not arePropertiesEnumerated(getReceiver().getALocalSource())
  }

  override predicate blocks(boolean outcome, Expr e) {
    e = getArgument(0).asExpr() and outcome = true
  }
}

/**
 * Sanitizer guard for `instanceof` expressions.
 *
 * `Object.prototype instanceof X` is never true, so this blocks the `__proto__` label.
 *
 * It is still possible to get to `Function.prototype` through `constructor.constructor.prototype`
 * so we do not block the `constructor` label.
 */
class InstanceOfGuard extends DataFlow::LabeledBarrierGuardNode, DataFlow::ValueNode {
  override InstanceOfExpr astNode;

  override predicate blocks(boolean outcome, Expr e, DataFlow::FlowLabel label) {
    e = astNode.getLeftOperand() and outcome = true and label = "__proto__"
  }
}

/**
 * Sanitizer guard of form `typeof x === "object"` or `typeof x === "function"`.
 *
 * The former blocks the `constructor` label as that payload must pass through a function,
 * and the latter blocks the `__proto__` label as that only passes through objects.
 */
class TypeofGuard extends DataFlow::LabeledBarrierGuardNode, DataFlow::ValueNode {
  override EqualityTest astNode;
  TypeofExpr typeof;
  string typeofStr;

  TypeofGuard() {
    typeof = astNode.getAnOperand() and
    typeofStr = astNode.getAnOperand().getStringValue()
  }

  override predicate blocks(boolean outcome, Expr e, DataFlow::FlowLabel label) {
    e = typeof.getOperand() and
    outcome = astNode.getPolarity() and
    (
      typeofStr = "object" and
      label = "constructor"
      or
      typeofStr = "function" and
      label = "__proto__"
    )
  }
}

/**
 * A check of form `["__proto__"].includes(x)` or similar.
 */
class ArrayInclusionGuard extends DataFlow::LabeledBarrierGuardNode, InclusionTest {
  UnsafePropLabel label;

  ArrayInclusionGuard() {
    exists(DataFlow::ArrayCreationNode array |
      array.getAnElement().getStringValue() = label and
      array.flowsTo(getContainerNode())
    )
  }

  override predicate blocks(boolean outcome, Expr e, DataFlow::FlowLabel lbl) {
    outcome = getPolarity().booleanNot() and
    e = getContainedNode().asExpr() and
    label = lbl
  }
}

/**
 * Gets a meaningful name for `node` if possible.
 */
string getExprName(DataFlow::Node node) {
  result = node.asExpr().(Identifier).getName()
  or
  result = node.asExpr().(DotExpr).getPropertyName()
}

/**
 * Gets a name to display for `node`.
 */
string deriveExprName(DataFlow::Node node) {
  result = getExprName(node)
  or
  not exists(getExprName(node)) and
  result = "this object"
}

/**
 * Holds if the dynamic property write `base[prop] = rhs` can pollute the prototype
 * of `base` due to flow from `enum`.
 *
 * In most cases this will result in an alert, the exception being the case where
 * `base` does not have a prototype at all.
 */
predicate isPrototypePollutingAssignment(Node base, Node prop, Node rhs, EnumeratedPropName enum) {
  dynamicPropWrite(base, prop, rhs) and
  exists(PropNameTracking cfg |
    cfg.hasFlow(enum, base) and
    cfg.hasFlow(enum, prop) and
    cfg.hasFlow(enum, rhs) and
    cfg.hasFlow(enum.getASourceProp(), rhs)
  )
}

/** Gets a data flow node leading to the base of a prototype-polluting assignment. */
private DataFlow::SourceNode getANodeLeadingToBase(DataFlow::TypeBackTracker t, Node base) {
  t.start() and
  isPrototypePollutingAssignment(base, _, _, _) and
  result = base.getALocalSource()
  or
  exists(DataFlow::TypeBackTracker t2 |
    result = getANodeLeadingToBase(t2, base).backtrack(t2, t)
  )
}

/**
 * Gets a data flow node leading to the base of dynamic property read leading to a
 * prototype-polluting assignment.
 *
 * For example, this is the `dst` in `dst[key1][key2] = ...`.
 * This dynamic read is where the reference to a built-in prototype object is obtained,
 * and we need this to ensure that this object actually has a prototype.
 */
private DataFlow::SourceNode getANodeLeadingToBaseBase(DataFlow::TypeBackTracker t, Node base) {
  exists(DynamicPropRead read |
    read = getANodeLeadingToBase(t, base) and
    result = read.getBase().getALocalSource()
  )
  or
  exists(DataFlow::TypeBackTracker t2 |
    result = getANodeLeadingToBaseBase(t2, base).backtrack(t2, t)
  )
}

DataFlow::SourceNode getANodeLeadingToBaseBase(Node base) {
  result = getANodeLeadingToBaseBase(DataFlow::TypeBackTracker::end(), base)
}

/** A call to `Object.create(null)`. */
class ObjectCreateNullCall extends CallNode {
  ObjectCreateNullCall() {
    this = globalVarRef("Object").getAMemberCall("create") and
    getArgument(0).asExpr() instanceof NullLiteral
  }
}

from
  PropNameTracking cfg, DataFlow::PathNode source, DataFlow::PathNode sink, EnumeratedPropName enum,
  Node base
where
  cfg.hasFlowPath(source, sink) and
  isPrototypePollutingAssignment(base, _, _, enum) and
  sink.getNode() = base and
  source.getNode() = enum and
  (
    getANodeLeadingToBaseBase(base) instanceof ObjectLiteralNode
    or
    not getANodeLeadingToBaseBase(base) instanceof ObjectCreateNullCall
  )
select base, source, sink,
  "Properties are copied from $@ to $@ without guarding against prototype pollution.",
  enum.getSourceObject(), deriveExprName(enum.getSourceObject()), base, deriveExprName(base)
