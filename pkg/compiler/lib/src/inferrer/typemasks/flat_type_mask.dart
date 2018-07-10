// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of masks;

/**
 * A flat type mask is a type mask that has been flattened to contain a
 * base type.
 */
class FlatTypeMask implements TypeMask {
  static const int EMPTY = 0;
  static const int EXACT = 1;
  static const int SUBCLASS = 2;
  static const int SUBTYPE = 3;

  final ClassEntity base;
  final int flags;

  FlatTypeMask(ClassEntity base, int kind, bool isNullable)
      : this.internal(base, (kind << 1) | (isNullable ? 1 : 0));

  FlatTypeMask.exact(ClassEntity base) : this.internal(base, (EXACT << 1) | 1);
  FlatTypeMask.subclass(ClassEntity base)
      : this.internal(base, (SUBCLASS << 1) | 1);
  FlatTypeMask.subtype(ClassEntity base)
      : this.internal(base, (SUBTYPE << 1) | 1);

  const FlatTypeMask.nonNullEmpty()
      : base = null,
        flags = 0;
  const FlatTypeMask.empty()
      : base = null,
        flags = 1;

  FlatTypeMask.nonNullExact(ClassEntity base) : this.internal(base, EXACT << 1);
  FlatTypeMask.nonNullSubclass(ClassEntity base)
      : this.internal(base, SUBCLASS << 1);
  FlatTypeMask.nonNullSubtype(ClassEntity base)
      : this.internal(base, SUBTYPE << 1);

  ClassQuery get _classQuery => isExact
      ? ClassQuery.EXACT
      : (isSubclass ? ClassQuery.SUBCLASS : ClassQuery.SUBTYPE);

  FlatTypeMask.internal(this.base, this.flags);

  /**
   * Ensures that the generated mask is normalized, i.e., a call to
   * [TypeMask.assertIsNormalized] with the factory's result returns `true`.
   */
  factory FlatTypeMask.normalized(
      ClassEntity base, int flags, JClosedWorld world) {
    if ((flags >> 1) == EMPTY || ((flags >> 1) == EXACT)) {
      return new FlatTypeMask.internal(base, flags);
    }
    if ((flags >> 1) == SUBTYPE) {
      if (!world.classHierarchy.hasAnyStrictSubtype(base) ||
          world.classHierarchy.hasOnlySubclasses(base)) {
        flags = (flags & 0x1) | (SUBCLASS << 1);
      }
    }
    if (((flags >> 1) == SUBCLASS) &&
        !world.classHierarchy.hasAnyStrictSubclass(base)) {
      flags = (flags & 0x1) | (EXACT << 1);
    }
    CommonMasks commonMasks = world.abstractValueDomain;
    return commonMasks.getCachedMask(
        base, flags, () => new FlatTypeMask.internal(base, flags));
  }

  bool get isEmpty => isEmptyOrNull && !isNullable;
  bool get isNull => isEmptyOrNull && isNullable;
  bool get isEmptyOrNull => (flags >> 1) == EMPTY;
  bool get isExact => (flags >> 1) == EXACT;
  bool get isNullable => (flags & 1) != 0;

  bool get isUnion => false;
  bool get isContainer => false;
  bool get isMap => false;
  bool get isDictionary => false;
  bool get isForwarding => false;
  bool get isValue => false;

  // TODO(kasperl): Get rid of these. They should not be a visible
  // part of the implementation because they make it hard to add
  // proper union types if we ever want to.
  bool get isSubclass => (flags >> 1) == SUBCLASS;
  bool get isSubtype => (flags >> 1) == SUBTYPE;

  TypeMask nullable() {
    return isNullable ? this : new FlatTypeMask.internal(base, flags | 1);
  }

  TypeMask nonNullable() {
    return isNullable ? new FlatTypeMask.internal(base, flags & ~1) : this;
  }

  bool contains(ClassEntity other, JClosedWorld closedWorld) {
    if (isEmptyOrNull) {
      return false;
    } else if (identical(base, other)) {
      return true;
    } else if (isExact) {
      return false;
    } else if (isSubclass) {
      return closedWorld.classHierarchy.isSubclassOf(other, base);
    } else {
      assert(isSubtype);
      return closedWorld.classHierarchy.isSubtypeOf(other, base);
    }
  }

  bool isSingleImplementationOf(ClassEntity cls, JClosedWorld closedWorld) {
    // Special case basic types so that, for example, JSString is the
    // single implementation of String.
    // The general optimization is to realize there is only one class that
    // implements [base] and [base] is not instantiated. We however do
    // not track correctly the list of truly instantiated classes.
    CommonElements commonElements = closedWorld.commonElements;
    if (containsOnlyString(closedWorld)) {
      return cls == closedWorld.commonElements.stringClass ||
          cls == commonElements.jsStringClass;
    }
    if (containsOnlyBool(closedWorld)) {
      return cls == closedWorld.commonElements.boolClass ||
          cls == commonElements.jsBoolClass;
    }
    if (containsOnlyInt(closedWorld)) {
      return cls == closedWorld.commonElements.intClass ||
          cls == commonElements.jsIntClass ||
          cls == commonElements.jsPositiveIntClass ||
          cls == commonElements.jsUInt32Class ||
          cls == commonElements.jsUInt31Class;
    }
    if (containsOnlyDouble(closedWorld)) {
      return cls == closedWorld.commonElements.doubleClass ||
          cls == commonElements.jsDoubleClass;
    }
    return false;
  }

  bool isInMask(TypeMask other, JClosedWorld closedWorld) {
    if (isEmptyOrNull) return isNullable ? other.isNullable : true;
    // The empty type contains no classes.
    if (other.isEmptyOrNull) return false;
    // Quick check whether to handle null.
    if (isNullable && !other.isNullable) return false;
    other = TypeMask.nonForwardingMask(other);
    // If other is union, delegate to UnionTypeMask.containsMask.
    if (other is! FlatTypeMask) return other.containsMask(this, closedWorld);
    // The other must be flat, so compare base and flags.
    FlatTypeMask flatOther = other;
    ClassEntity otherBase = flatOther.base;
    // If other is exact, it only contains its base.
    // TODO(herhut): Get rid of isSingleImplementationOf.
    if (flatOther.isExact) {
      return (isExact && base == otherBase) ||
          isSingleImplementationOf(otherBase, closedWorld);
    }
    // If other is subclass, this has to be subclass, as well. Unless
    // flatOther.base covers all subtypes of this. Currently, we only
    // consider object to behave that way.
    // TODO(herhut): Add check whether flatOther.base is superclass of
    //               all subclasses of this.base.
    if (flatOther.isSubclass) {
      if (isSubtype)
        return (otherBase == closedWorld.commonElements.objectClass);
      return closedWorld.classHierarchy.isSubclassOf(base, otherBase);
    }
    assert(flatOther.isSubtype);
    // Check whether this TypeMask satisfies otherBase's interface.
    return satisfies(otherBase, closedWorld);
  }

  bool containsMask(TypeMask other, JClosedWorld closedWorld) {
    return other.isInMask(this, closedWorld);
  }

  bool containsOnlyInt(JClosedWorld closedWorld) {
    CommonElements commonElements = closedWorld.commonElements;
    return base == closedWorld.commonElements.intClass ||
        base == commonElements.jsIntClass ||
        base == commonElements.jsPositiveIntClass ||
        base == commonElements.jsUInt31Class ||
        base == commonElements.jsUInt32Class;
  }

  bool containsOnlyDouble(JClosedWorld closedWorld) {
    return base == closedWorld.commonElements.doubleClass ||
        base == closedWorld.commonElements.jsDoubleClass;
  }

  bool containsOnlyNum(JClosedWorld closedWorld) {
    return containsOnlyInt(closedWorld) ||
        containsOnlyDouble(closedWorld) ||
        base == closedWorld.commonElements.numClass ||
        base == closedWorld.commonElements.jsNumberClass;
  }

  bool containsOnlyBool(JClosedWorld closedWorld) {
    return base == closedWorld.commonElements.boolClass ||
        base == closedWorld.commonElements.jsBoolClass;
  }

  bool containsOnlyString(JClosedWorld closedWorld) {
    return base == closedWorld.commonElements.stringClass ||
        base == closedWorld.commonElements.jsStringClass;
  }

  bool containsOnly(ClassEntity cls) {
    return base == cls;
  }

  bool satisfies(ClassEntity cls, JClosedWorld closedWorld) {
    if (isEmptyOrNull) return false;
    if (closedWorld.classHierarchy.isSubtypeOf(base, cls)) return true;
    return false;
  }

  /// Returns the [Entity] if this type represents a single class, otherwise
  /// returns `null`.  This method is conservative.
  ClassEntity singleClass(JClosedWorld closedWorld) {
    if (isEmptyOrNull) return null;
    if (isNullable) return null; // It is Null and some other class.
    if (isExact) {
      return base;
    } else if (isSubclass) {
      return closedWorld.classHierarchy.hasAnyStrictSubclass(base)
          ? null
          : base;
    } else {
      assert(isSubtype);
      return null;
    }
  }

  /**
   * Returns whether or not this type mask contains all types.
   */
  bool containsAll(JClosedWorld closedWorld) {
    if (isEmptyOrNull || isExact) return false;
    return identical(base, closedWorld.commonElements.objectClass);
  }

  TypeMask union(TypeMask other, JClosedWorld closedWorld) {
    assert(other != null);
    assert(TypeMask.assertIsNormalized(this, closedWorld));
    assert(TypeMask.assertIsNormalized(other, closedWorld));
    if (other is! FlatTypeMask) return other.union(this, closedWorld);
    FlatTypeMask flatOther = other;
    if (isEmptyOrNull) {
      return isNullable ? flatOther.nullable() : flatOther;
    } else if (flatOther.isEmptyOrNull) {
      return flatOther.isNullable ? nullable() : this;
    } else if (base == flatOther.base) {
      return unionSame(flatOther, closedWorld);
    } else if (closedWorld.classHierarchy.isSubclassOf(flatOther.base, base)) {
      return unionStrictSubclass(flatOther, closedWorld);
    } else if (closedWorld.classHierarchy.isSubclassOf(base, flatOther.base)) {
      return flatOther.unionStrictSubclass(this, closedWorld);
    } else if (closedWorld.classHierarchy.isSubtypeOf(flatOther.base, base)) {
      return unionStrictSubtype(flatOther, closedWorld);
    } else if (closedWorld.classHierarchy.isSubtypeOf(base, flatOther.base)) {
      return flatOther.unionStrictSubtype(this, closedWorld);
    } else {
      return new UnionTypeMask._internal(<FlatTypeMask>[this, flatOther]);
    }
  }

  TypeMask unionSame(FlatTypeMask other, JClosedWorld closedWorld) {
    assert(base == other.base);
    assert(TypeMask.assertIsNormalized(this, closedWorld));
    assert(TypeMask.assertIsNormalized(other, closedWorld));
    // The two masks share the base type, so we must chose the least
    // constraining kind (the highest) of the two. If either one of
    // the masks are nullable the result should be nullable too.
    // As both masks are normalized, the result will be, too.
    int combined = (flags > other.flags)
        ? flags | (other.flags & 1)
        : other.flags | (flags & 1);
    if (flags == combined) {
      return this;
    } else if (other.flags == combined) {
      return other;
    } else {
      return new FlatTypeMask.normalized(base, combined, closedWorld);
    }
  }

  TypeMask unionStrictSubclass(FlatTypeMask other, JClosedWorld closedWorld) {
    assert(base != other.base);
    assert(closedWorld.classHierarchy.isSubclassOf(other.base, base));
    assert(TypeMask.assertIsNormalized(this, closedWorld));
    assert(TypeMask.assertIsNormalized(other, closedWorld));
    int combined;
    if ((isExact && other.isExact) ||
        base == closedWorld.commonElements.objectClass) {
      // Since the other mask is a subclass of this mask, we need the
      // resulting union to be a subclass too. If either one of the
      // masks are nullable the result should be nullable too.
      combined = (SUBCLASS << 1) | ((flags | other.flags) & 1);
    } else {
      // Both masks are at least subclass masks, so we pick the least
      // constraining kind (the highest) of the two. If either one of
      // the masks are nullable the result should be nullable too.
      combined = (flags > other.flags)
          ? flags | (other.flags & 1)
          : other.flags | (flags & 1);
    }
    // If we weaken the constraint on this type, we have to make sure that
    // the result is normalized.
    return (flags != combined)
        ? new FlatTypeMask.normalized(base, combined, closedWorld)
        : this;
  }

  TypeMask unionStrictSubtype(FlatTypeMask other, JClosedWorld closedWorld) {
    assert(base != other.base);
    assert(!closedWorld.classHierarchy.isSubclassOf(other.base, base));
    assert(closedWorld.classHierarchy.isSubtypeOf(other.base, base));
    assert(TypeMask.assertIsNormalized(this, closedWorld));
    assert(TypeMask.assertIsNormalized(other, closedWorld));
    // Since the other mask is a subtype of this mask, we need the
    // resulting union to be a subtype too. If either one of the masks
    // are nullable the result should be nullable too.
    int combined = (SUBTYPE << 1) | ((flags | other.flags) & 1);
    // We know there is at least one subtype, [other.base], so no need
    // to normalize.
    return (flags != combined)
        ? new FlatTypeMask.normalized(base, combined, closedWorld)
        : this;
  }

  TypeMask intersection(TypeMask other, JClosedWorld closedWorld) {
    assert(other != null);
    if (other is! FlatTypeMask) return other.intersection(this, closedWorld);
    assert(TypeMask.assertIsNormalized(this, closedWorld));
    assert(TypeMask.assertIsNormalized(other, closedWorld));
    FlatTypeMask flatOther = other;

    ClassEntity otherBase = flatOther.base;

    bool includeNull = isNullable && flatOther.isNullable;

    if (isEmptyOrNull) {
      return includeNull ? this : nonNullable();
    } else if (flatOther.isEmptyOrNull) {
      return includeNull ? other : other.nonNullable();
    }

    SubclassResult result = closedWorld.classHierarchy
        .commonSubclasses(base, _classQuery, otherBase, flatOther._classQuery);

    switch (result.kind) {
      case SubclassResultKind.EMPTY:
        return includeNull
            ? closedWorld.abstractValueDomain.nullType
            : closedWorld.abstractValueDomain.emptyType;
      case SubclassResultKind.EXACT1:
        assert(isExact);
        return includeNull ? this : nonNullable();
      case SubclassResultKind.EXACT2:
        assert(other.isExact);
        return includeNull ? other : other.nonNullable();
      case SubclassResultKind.SUBCLASS1:
        assert(isSubclass);
        return includeNull ? this : nonNullable();
      case SubclassResultKind.SUBCLASS2:
        assert(flatOther.isSubclass);
        return includeNull ? other : other.nonNullable();
      case SubclassResultKind.SUBTYPE1:
        assert(isSubtype);
        return includeNull ? this : nonNullable();
      case SubclassResultKind.SUBTYPE2:
        assert(flatOther.isSubtype);
        return includeNull ? other : other.nonNullable();
      case SubclassResultKind.SET:
      default:
        if (result.classes.isEmpty) {
          return includeNull
              ? closedWorld.abstractValueDomain.nullType
              : closedWorld.abstractValueDomain.emptyType;
        } else if (result.classes.length == 1) {
          ClassEntity cls = result.classes.first;
          return includeNull
              ? new TypeMask.subclass(cls, closedWorld)
              : new TypeMask.nonNullSubclass(cls, closedWorld);
        }

        List<FlatTypeMask> masks = <FlatTypeMask>[];
        if (includeNull) {
          for (ClassEntity cls in result.classes) {
            masks.add(new TypeMask.subclass(cls, closedWorld));
          }
        } else {
          for (ClassEntity cls in result.classes) {
            masks.add(new TypeMask.nonNullSubclass(cls, closedWorld));
          }
        }
        if (masks.length > UnionTypeMask.MAX_UNION_LENGTH) {
          return UnionTypeMask.flatten(masks, closedWorld);
        }
        return new UnionTypeMask._internal(masks);
    }
  }

  bool isDisjoint(TypeMask other, JClosedWorld closedWorld) {
    if (other is! FlatTypeMask) return other.isDisjoint(this, closedWorld);
    FlatTypeMask flatOther = other;

    if (isNullable && flatOther.isNullable) return false;
    if (isEmptyOrNull || flatOther.isEmptyOrNull) return true;
    if (base == flatOther.base) return false;
    if (isExact && flatOther.isExact) return true;

    if (isExact) return !flatOther.contains(base, closedWorld);
    if (flatOther.isExact) return !contains(flatOther.base, closedWorld);

    // Normalization guarantees that isExact === !isSubclass && !isSubtype.
    // Both are subclass or subtype masks, so if there is a subclass
    // relationship, they are not disjoint.
    if (closedWorld.classHierarchy.isSubclassOf(flatOther.base, base)) {
      return false;
    }
    if (closedWorld.classHierarchy.isSubclassOf(base, flatOther.base)) {
      return false;
    }

    // Two different base classes have no common subclass unless one is a
    // subclass of the other (checked above).
    if (isSubclass && flatOther.isSubclass) return true;

    return _isDisjointHelper(this, flatOther, closedWorld);
  }

  static bool _isDisjointHelper(
      FlatTypeMask a, FlatTypeMask b, JClosedWorld closedWorld) {
    if (!a.isSubclass && b.isSubclass) {
      return _isDisjointHelper(b, a, closedWorld);
    }
    assert(a.isSubclass || a.isSubtype);
    assert(b.isSubtype);
    var elements = a.isSubclass
        ? closedWorld.classHierarchy.strictSubclassesOf(a.base)
        : closedWorld.classHierarchy.strictSubtypesOf(a.base);
    for (var element in elements) {
      if (closedWorld.classHierarchy.isSubtypeOf(element, b.base)) return false;
    }
    return true;
  }

  TypeMask intersectionSame(FlatTypeMask other, JClosedWorld closedWorld) {
    assert(base == other.base);
    // The two masks share the base type, so we must chose the most
    // constraining kind (the lowest) of the two. Only if both masks
    // are nullable, will the result be nullable too.
    // The result will be normalized, as the two inputs are normalized, too.
    int combined = (flags < other.flags)
        ? flags & ((other.flags & 1) | ~1)
        : other.flags & ((flags & 1) | ~1);
    if (flags == combined) {
      return this;
    } else if (other.flags == combined) {
      return other;
    } else {
      return new FlatTypeMask.normalized(base, combined, closedWorld);
    }
  }

  TypeMask intersectionStrictSubclass(
      FlatTypeMask other, JClosedWorld closedWorld) {
    assert(base != other.base);
    assert(closedWorld.classHierarchy.isSubclassOf(other.base, base));
    // If this mask isn't at least a subclass mask, then the
    // intersection with the other mask is empty.
    if (isExact) return intersectionEmpty(other);
    // Only the other mask puts constraints on the intersection mask,
    // so base the combined flags on the other mask. Only if both
    // masks are nullable, will the result be nullable too.
    // The result is guaranteed to be normalized, as the other type
    // was normalized.
    int combined = other.flags & ((flags & 1) | ~1);
    if (other.flags == combined) {
      return other;
    } else {
      return new FlatTypeMask.normalized(other.base, combined, closedWorld);
    }
  }

  TypeMask intersectionEmpty(FlatTypeMask other) {
    return isNullable && other.isNullable
        ? new TypeMask.empty()
        : new TypeMask.nonNullEmpty();
  }

  /**
   * Returns whether [element] is a potential target when being
   * invoked on this type mask. [selector] is used to ensure library
   * privacy is taken into account.
   */
  bool canHit(
      MemberEntity element, Selector selector, JClosedWorld closedWorld) {
    CommonElements commonElements = closedWorld.commonElements;
    assert(element.name == selector.name);
    if (isEmpty) return false;
    if (isNull) {
      return closedWorld.hasElementIn(
          commonElements.jsNullClass, selector, element);
    }

    ClassEntity other = element.enclosingClass;
    if (other == commonElements.jsNullClass) {
      return isNullable;
    } else if (isExact) {
      return closedWorld.hasElementIn(base, selector, element);
    } else if (isSubclass) {
      return closedWorld.hasElementIn(base, selector, element) ||
          closedWorld.classHierarchy.isSubclassOf(other, base) ||
          closedWorld.hasAnySubclassThatMixes(base, other);
    } else {
      assert(isSubtype);
      bool result = closedWorld.hasElementIn(base, selector, element) ||
          closedWorld.classHierarchy.isSubtypeOf(other, base) ||
          closedWorld.hasAnySubclassThatImplements(other, base) ||
          closedWorld.hasAnySubclassOfMixinUseThatImplements(other, base);
      if (result) return true;
      // If the class is used as a mixin, we have to check if the element
      // can be hit from any of the mixin applications.
      Iterable<ClassEntity> mixinUses = closedWorld.mixinUsesOf(base);
      return mixinUses.any((mixinApplication) =>
          closedWorld.hasElementIn(mixinApplication, selector, element) ||
          closedWorld.classHierarchy.isSubclassOf(other, mixinApplication) ||
          closedWorld.hasAnySubclassThatMixes(mixinApplication, other));
    }
  }

  bool needsNoSuchMethodHandling(
      Selector selector, covariant JClosedWorld closedWorld) {
    // A call on an empty type mask is either dead code, or a call on
    // `null`.
    if (isEmptyOrNull) return false;
    // A call on an exact mask for an abstract class is dead code.
    // TODO(johnniwinther): A type mask cannot be abstract. Remove the need
    // for this noise (currently used for super-calls in inference and mirror
    // usage).
    if (isExact && base.isAbstract) return false;

    return closedWorld.needsNoSuchMethod(base, selector, _classQuery);
  }

  MemberEntity locateSingleMember(Selector selector, JClosedWorld closedWorld) {
    if (isEmptyOrNull) return null;
    if (closedWorld.includesClosureCall(selector, this)) return null;
    Iterable<MemberEntity> targets = closedWorld.locateMembers(selector, this);
    if (targets.length != 1) return null;
    MemberEntity result = targets.first;
    ClassEntity enclosing = result.enclosingClass;
    // We only return the found element if it is guaranteed to be implemented on
    // all classes in the receiver type [this]. It could be found only in a
    // subclass or in an inheritance-wise unrelated class in case of subtype
    // selectors.
    if (isSubtype) {
      // if (closedWorld.isUsedAsMixin(enclosing)) {
      if (closedWorld.everySubtypeIsSubclassOfOrMixinUseOf(base, enclosing)) {
        return result;
      }
      //}
      return null;
    } else {
      if (closedWorld.classHierarchy.isSubclassOf(base, enclosing)) {
        return result;
      }
      if (closedWorld.isSubclassOfMixinUseOf(base, enclosing)) return result;
    }
    return null;
  }

  bool operator ==(var other) {
    if (identical(this, other)) return true;
    if (other is! FlatTypeMask) return false;
    FlatTypeMask otherMask = other;
    return (flags == otherMask.flags) && (base == otherMask.base);
  }

  int get hashCode {
    return (base == null ? 0 : base.hashCode) + 31 * flags.hashCode;
  }

  String toString() {
    if (isEmptyOrNull) return isNullable ? '[null]' : '[empty]';
    StringBuffer buffer = new StringBuffer();
    if (isNullable) buffer.write('null|');
    if (isExact) buffer.write('exact=');
    if (isSubclass) buffer.write('subclass=');
    if (isSubtype) buffer.write('subtype=');
    buffer.write(base.name);
    return "[$buffer]";
  }
}
