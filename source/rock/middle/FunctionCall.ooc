import structs/[ArrayList, List, HashMap]
import ../frontend/[Token, BuildParams, CommandLine]
import Visitor, Expression, FunctionDecl, Argument, Type, VariableAccess,
       TypeDecl, Node, VariableDecl, AddressOf, CommaSequence, BinaryOp,
       InterfaceDecl, Cast, NamespaceDecl, BaseType, FuncType, Return,
       TypeList, Scope, Block, InlineContext, StructLiteral, NullLiteral,
       IntLiteral
import tinker/[Response, Resolver, Trail, Errors]

/**
 * Every function call, member or not, is represented by this AST node.
 *
 * Member calls (ie. "blah" println()) have a non-null 'expr'
 *
 * Calls to functions with generic type arguments store the 'resolution'
 * of these type arguments in the typeArgs list. Until all type arguments
 * are resolved, the function call is not fully resolved.
 *
 * Calls to functions that have multi-returns or a generic return type
 * use returnArgs expression (secret variables that are references,
 * and are assigned to when the return happens.)
 *
 * @author Amos Wenger (nddrylliog)
 */

IMPLICIT_AS_EXTERNAL_ONLY: const Bool = true

FunctionCall: class extends Expression {

    /**
     * Expression on which we call something, if any. Function calls
     * have a null expr, method calls have a non-null ones.
     */
    expr: Expression

    /** Name of the function being called. */
    name: String

    /**
     * If the suffix is non-null (ie it has been specified in the code,
     * via name~suffix()), it won't accept functions that have a different
     * suffix.
     *
     * If suffix is null, it'll just try to find the best match, no matter
     * the suffix.
     */
    suffix = null : String

    /**
     * Resolved declaration's type arguments. For example,
     * ArrayList<Int> new() will have 'Int' in its typeArgs.
     */
    typeArgs := ArrayList<Expression> new()

    /**
     * Calls to functions that have multi-returns or a generic return type
     * use returnArgs expression (secret variables that are references,
     * and are assigned to when the return happens.)
     */
    returnArgs := ArrayList<Expression> new()

    /**
     * Inferred return type of the call - might be different from ref's returnType
     * if it is generic, for example.
     */
    returnType : Type = null

    args := ArrayList<Expression> new()

    /**
     * The actual function declaration this call is calling.
     * Note that this makes rock almost a linker too - it effectively
     * knows the ins and outs of all your calls before it dares
     * generate C code.
     */
    ref = null : FunctionDecl

    /**
     * By default member method calls are virtual calls, ie. they call
     * the implementation of the *actual*, concrete class of the object it's called
     * on, not on the abstract class we might be calling it on.
     *
     * This is only used internally when we really want to call the _impl variant
     * instead.
     */
    virtual := true

    /**
     * < 0 = not resolved (incompatible functions)
     * > 0 = resolved
     *
     * Score is determined in getScore(), depending on the arguments, etc.
     *
     * Function declarations that don't even match the name don't even
     * have a score.
     */
    refScore := INT_MIN

    /**
     * When 'implicit as' is used, args are modified, and this map
     * keeps track of what has been modified, to be able to restore it.
     */
    argsBeforeConversion: HashMap<Int, Expression>
    candidateUsesAs := false

    /**
     * Create a new function call to the function '<name>()'
     */
    init: func ~funcCall (=name, .token) {
        super(token)
    }

    /**
     * Create a new method (member function) call to the function 'expr <name>()'
     */
    init: func ~functionCallWithExpr (=expr, =name, .token) {
        super(token)
    }

    clone: func -> This {
        copy := new(expr, name, token)
        copy suffix = suffix
        args each(|e| copy args add(e clone()))
        copy
    }

    setExpr: func (=expr) {}
    getExpr: func -> Expression { expr }

    setName: func (=name) {}
    getName: func -> String { name }

    setSuffix: func (=suffix) {}
    getSuffix: func -> String { suffix }

    accept: func (visitor: Visitor) {
        visitor visitFunctionCall(this)
    }

    /**
     * Internal method used to print a shitload of debugging messages
     * on a particular function - used in one-shots of hardcore debugging.
     *
     * Usually has 'name == "something"' instead of 'false' as
     * a return expression, when it's being used.
     */
    debugCondition: inline func -> Bool {
        false
    }

    /**
     * This method is being called by other AST nodes that want to suggest
     * a function declaration to this function call.
     *
     * The call then evaluates the score of the decl, and if it has a higher score,
     * stores it as its new best ref.
     */
    suggest: func (candidate: FunctionDecl, res: Resolver, trail: Trail) -> Bool {

        if(debugCondition()) "** [refScore = %d] Got suggestion %s for %s" cformat(refScore, candidate toString() toCString(), toString() toCString()) println()

        if(isMember() && candidate owner == null) {
            if(debugCondition()) printf("** %s is no fit!, we need something to fit %s\n", candidate toString() toCString(), toString() toCString())
            return false
        }

        score := getScore(candidate)
        if(score == -1) {
            if(debugCondition()) "** Score = -1! Aboort" println()
            if(res fatal) {
                // trigger a resolve on the candidate so that it'll display a more helpful error
                candidate resolve(trail, res)
            }
            return false
        }

        if(score > refScore) {
            if(debugCondition()) "** New high score, %d/%s wins against %d/%s" cformat(score, candidate toString() toCString(), refScore, ref ? ref toString()  toCString(): "(nil)" toCString()) println()
            refScore = score
            ref = candidate

            // todo: optimize that. not all of this needs to happen in many cases
            if(argsBeforeConversion) {
                for(i in argsBeforeConversion getKeys()) {
                    callArg := argsBeforeConversion[i]
                    args set(i, callArg)
                }
            }
            candidateUsesAs = false

            for(i in 0..args getSize()) {
                if(i >= candidate args getSize()) break
                declArg := candidate args get(i)
                if(declArg instanceOf?(VarArg)) break
                callArg := args get(i)
                declArgType := declArg getType() refToPointer()
                if (declArgType isGeneric()) {
                    declArgType = declArgType realTypize(this)
                }
                if(callArg getType() == null) {
                    return false
                }

                if(callArg getType() getScore(declArgType) == Type NOLUCK_SCORE) {
                    ref := callArg getType() getRef()
                    if(ref instanceOf?(TypeDecl)) {
                        ref as TypeDecl implicitConversions each(|opdecl|
                            if(opdecl fDecl getReturnType() equals?(declArgType)) {
                                candidateUsesAs = true
                                if(!(IMPLICIT_AS_EXTERNAL_ONLY) || candidate isExtern()) {
                                    args set(i, Cast new(callArg, declArgType, callArg token))
                                    if(!argsBeforeConversion) {
                                        // lazy instantiation of argsBeforeConversion
                                        argsBeforeConversion = HashMap<Int, Expression> new()
                                    }
                                    argsBeforeConversion put(i, callArg)
                                }
                            }
                        )
                    }
                }
            }
            return score > 0
        }
        return false

    }

    resolve: func (trail: Trail, res: Resolver) -> Response {

        if(debugCondition() || res params veryVerbose) {
            printf("===============================================================\n")
            printf("     - Resolving call to %s (ref = %s)\n", name toCString(), ref ? ref toString() toCString(): "(nil)" toCString())
        }

        // resolve all arguments
        if(args getSize() > 0) {
            trail push(this)
            i := 0
            for(arg in args) {
                if(debugCondition() || res params veryVerbose) {
                    "resolving arg %s" cformat(arg toString() toCString()) println()
                }
                response := arg resolve(trail, res)
                if(!response ok()) {
                    trail pop(this)
                    return response
                }
                i += 1
            }
            trail pop(this)
        }

        // resolve our expr. e.g. in
        //     object doThing()
        // object is our expr.
        if(expr) {
            trail push(this)
            response := expr resolve(trail, res)
            trail pop(this)
            if(!response ok()) {
                if(res params veryVerbose) printf("Failed to resolve expr %s of call %s, looping\n", expr toString() toCString(), toString() toCString())
                return response
            }
        }

        // resolve all returnArgs (secret arguments used when we have
        // multi-return and/or generic return type
        for(i in 0..returnArgs getSize()) {
            returnArg := returnArgs[i]
            if(!returnArg) continue // they can be null, after all.

            response := returnArg resolve(trail, res)
            if(!response ok()) return response

            if(returnArg isResolved() && !returnArg instanceOf?(AddressOf)) {
                returnArgs[i] = returnArg getGenericOperand()
            }
        }

        /*
         * Try to resolve the call.
         *
         * We don't only have to find one definition, we have to find
         * the *best* one. For that, we're sticking to our fun score
         * system. A call can determine the score of a decl, based
         * mostly on the types of the arguments, the suffix, etc.
         *
         * Since we're looking for the best, we have to do the whole
         * trail from top to bottom
         */
        if(refScore <= 0) {
            if(debugCondition()) printf("\n===============\nResolving call %s\n", toString() toCString())
            if(name == "super") {
                fDecl := trail get(trail find(FunctionDecl), FunctionDecl)
                superTypeDecl := fDecl owner getSuperRef()
                finalScore: Int
                ref = superTypeDecl getMeta() getFunction(fDecl getName(), null, this, finalScore&)
                if(finalScore == -1) {
                    res wholeAgain(this, "something in our typedecl's functions needs resolving!")
                    return Response OK
                }
                if(ref != null) {
                    refScore = 1
                    expr = VariableAccess new(superTypeDecl getThisDecl(), token)
                    if(args empty?() && !ref getArguments() empty?()) {
                        for(declArg in fDecl getArguments()) {
                            args add(VariableAccess new(declArg, token))
                        }
                    }
                }
            } else {
                if(expr == null) {
                    depth := trail getSize() - 1
                    while(depth >= 0) {
                        node := trail get(depth, Node)
                        if(node resolveCall(this, res, trail) == -1) {
                            res wholeAgain(this, "Waiting on other nodes to resolve before resolving call.")
                            return Response OK
                        }

                        if(ref) {
                            if(ref vDecl) {
                                closureIndex := trail find(FunctionDecl)

                                if(closureIndex > depth) { // if it's not found (-1), this will be false anyway
                                    closure := trail get(closureIndex) as FunctionDecl
                                    if(closure isAnon && expr == null) {
                                        closure markForPartialing(ref vDecl, "v")
                                    }
                                }
                            }
                        }
                        depth -= 1
                    }
                } else if(expr instanceOf?(VariableAccess) && expr as VariableAccess getRef() != null && expr as VariableAccess getRef() instanceOf?(NamespaceDecl)) {
                    expr as VariableAccess getRef() resolveCall(this, res, trail)
                } else if(expr getType() != null && expr getType() getRef() != null) {
                    if(!expr getType() getRef() instanceOf?(TypeDecl)) {
                        message := "No such function %s%s for `%s`" cformat(name toCString(), getArgsTypesRepr() toCString(), expr getType() getName() toCString())
                        if(expr getType() isGeneric()) {
                            message += " (you can't call methods on generic types! you have to cast them first)"
                        }
                        res throwError(UnresolvedCall new(this, message, ""))
                    }
                    tDecl := expr getType() getRef() as TypeDecl
                    meta := tDecl getMeta()
                    if(debugCondition()) printf("Got tDecl %s, resolving, meta = %s\n", tDecl toString() toCString(), meta == null ? "(nil)" toCString(): meta toString() toCString())
                    if(meta) {
                        meta resolveCall(this, res, trail)
                    } else {
                        tDecl resolveCall(this, res, trail)
                    }
                }
            }
        }

        /*
         * Now resolve return type, generic type arguments, and interfaces
         */
        if(refScore > 0) {

            if(!resolveReturnType(trail, res) ok()) {
                res wholeAgain(this, "looping because of return type!")
                return Response OK
            }

            // resolved. if we're inlining, do it now!
            // FIXME: this is oh-so-primitive.
            if(res params inlining && ref doInline) {
                if(expr && (expr getType() == null || !expr getType() isResolved())) {
                    res wholeAgain(this, "need expr type!")
                    return Response OK
                }

                "Inlining %s! type = %s" cformat(toString() toCString(), getType() ? getType() toString() toCString() : "<unknown>" toCString()) println()

                retDecl := VariableDecl new(getType(), generateTempName("retval"), token)
                retAcc := VariableAccess new(retDecl, token)
                trail addBeforeInScope(this, retDecl)

                block := InlineContext new(this, token)
                block returnArgs add(retDecl) // Note: this isn't sufficient. What with TypeList return types?

                reservedNames := ref args map(|arg| arg name)

                for(i in 0..args getSize()) {
                    callArg := args get(i)

                    name := ref args get(i) getName()

                    if(callArg instanceOf?(VariableAccess)) {
                        vAcc := callArg as VariableAccess
                        if(reservedNames contains?(vAcc getName())) {
                            tempDecl := VariableDecl new(null, generateTempName(name), callArg, callArg token)
                            block body add(0, tempDecl)
                            callArg = VariableAccess new(tempDecl, tempDecl token)
                        }
                    }

                    block body add(VariableDecl new(null, name, callArg, callArg token))
                }

                ref inlineCopy getBody() list each(|x|
                    block body add(x clone())
                )

                trail addBeforeInScope(this, block)
                trail peek() replace(this, retAcc)

                res wholeAgain(this, "finished inlining")
                return Response OK
            }

            if(!handleGenerics(trail, res) ok()) {
                res wholeAgain(this, "looping because of generics!")
                return Response OK
            }

            if(!handleOptargs(trail, res) ok()) {
                res wholeAgain(this, "looping because of optargs!")
                return Response OK
            }

            if(!handleVarargs(trail, res) ok()) {
                res wholeAgain(this, "looping because of varargs!")
                return Response OK
            }

            if(!handleInterfaces(trail, res) ok()) {
                res wholeAgain(this, "looping because of interfaces!")
                return Response OK
            }

            if(typeArgs getSize() > 0) {
                trail push(this)
                for(typeArg in typeArgs) {
                    response := typeArg resolve(trail, res)
                    if(!response ok()) {
                        trail pop(this)
                        res wholeAgain(this, "typeArg failed to resolve\n")
                        return Response OK
                    }
                }
                trail pop(this)
            }

            unwrapIfNeeded(trail, res)

        }

        if(returnType) {
            response := returnType resolve(trail, res)
            if(!response ok()) return response

            if(returnType void?) {
                parent := trail peek()
                if(!parent instanceOf?(Scope)) {
                    res throwError(UseOfVoidExpression new(token, "Use of a void function call as an expression"))
                }
            }
        }

        if(refScore <= 0) {

            precisions := ""

            // Still no match, and in the fatal round? Throw an error.
            if(res fatal) {
                message := "No such function"
                if(expr == null) {
                    message = "No such function %s%s" cformat(name toCString(), getArgsTypesRepr() toCString())
                } else if(expr getType() != null) {
                    if(res params veryVerbose) {
                        message = "No such function %s%s for `%s` (%s)" cformat(name toCString(), getArgsTypesRepr() toCString(),
                            expr getType() toString() toCString(), expr getType() getRef() ? expr getType() getRef() token toString() toCString() : "(nil)" toCString())
                    } else {
                        message = "No such function %s%s for `%s`" cformat(name toCString(), getArgsTypesRepr() toCString(), expr getType() toString() toCString())
                    }
                }

                if(ref) {
                    // If we have a near-match, show it here.
                    precisions += showNearestMatch(res params)
                    // TODO: add levenshtein distance

                    if (ref && candidateUsesAs) {
                        precisions += "\n\n(Hint: 'implicit as' isn't allowed on non-extern functions)"
                    }
                } else {
                    if(res params helpful) {
                        // Try to find such a function in other modules in the sourcepath
                        similar := findSimilar(res)
                        if(similar) message += similar
                    }
                }
                res throwError(UnresolvedCall new(this, message, precisions))
            } else {
                res wholeAgain(this, "not resolved")
                return Response OK
            }

        }

        // finally, avoid & on lvalues: unwrap unreferencable expressions.
        if(ref && ref isThisRef && expr && !expr isReferencable()) {
            vDecl := VariableDecl new(null, generateTempName("hi_mum"), expr, expr token)
            trail addBeforeInScope(this, vDecl)
            expr = VariableAccess new(vDecl, expr token)
            return Response OK
        }

        return Response OK

    }

    findSimilar: func (res: Resolver) -> String {

        buff := Buffer new()

        for(imp in res collectAllImports()) {
            module := imp getModule()

            fDecl := module getFunctions() get(name)
            if(fDecl) {
                buff append(" (Hint: there's such a function in "). append(imp getPath()). append(")")
            }
        }

        buff toString()

    }

    /**
     * If we have a ref but with a negative score, it means there's a function
     * with the right name, but that doesn't match in respect with the arguments
     */
    showNearestMatch: func (params: BuildParams) -> String {
        b := Buffer new()

        b append("\n\n\tNearest match is:\n\n\t\t%s\n" cformat(ref toString(this) toCString()))

        callIter := args iterator()
        declIter := ref args iterator()

        while(callIter hasNext?() && declIter hasNext?()) {
            declArg := declIter next()
            if(declArg instanceOf?(VarArg)) break
            callArg := callIter next()

            if(declArg getType() == null) {
                b append(declArg token formatMessage("\tbut couldn't resolve type of this argument in the declaration\n", ""))
                continue
            }

            if(callArg getType() == null) {
                b append(callArg token formatMessage("\tbut couldn't resolve type of this argument in the call\n", ""))
                continue
            }

            declArgType := declArg getType()
            if(declArgType isGeneric()) {
                declArgType = declArgType realTypize(this)
            }

            score := callArg getType() getScore(declArgType)
            if(score < 0) {
                if(params veryVerbose) {
                    b append("\t..but the type of this arg should be `%s` (%s), not %s (%s)\n" cformat(declArgType toString() toCString(), declArgType getRef() ? declArgType getRef() token toString() toCString() : "(nil)" toCString(),
                                                                                           callArg getType() toString() toCString(), callArg getType() getRef() ? callArg getType() getRef() token toString() toCString() : "(nil)" toCString()))
                } else {
                    b append("\t..but the type of this arg (%s) should be `%s`, not `%s`\n" cformat(callArg toString() toCString(), declArgType toString() toCString(), callArg getType() toString() toCString()))
                }
                b append(token formatMessage("\t\t", "", ""))
            }
        }

        b toString()
    }

    unwrapIfNeeded: func (trail: Trail, res: Resolver) -> Response {

        parent := trail peek()

        if(ref == null || ref returnType == null) {
            res wholeAgain(this, "need ref and refType")
            return Response OK
        }

        idx := 2
        while(parent instanceOf?(Cast)) {
            parent = trail peek(idx)
            idx += 1
        }

        if(!ref getReturnArgs() empty?() && !isFriendlyHost(parent)) {
            if(parent instanceOf?(Return)) {
                fDeclIdx := trail find(FunctionDecl)
                if(fDeclIdx != -1) {
                    fDecl := trail get(fDeclIdx) as FunctionDecl
                    retType := fDecl getReturnType()
                    if(!retType isResolved()) {
                        res wholeAgain(this, "Need fDecl returnType to be resolved")
                        return Response OK
                    }
                    if(retType isGeneric()) {
                        // will be handled by Return resolve()
                        return Response OK
                    }
                }
            }

            vType := getType() instanceOf?(TypeList) ? getType() as TypeList types get(0) : getType()
            vDecl := VariableDecl new(vType, generateTempName("genCall"), token)
            if(!trail addBeforeInScope(this, vDecl)) {
                if(res fatal) res throwError(CouldntAddBeforeInScope new(token, vDecl, this, trail))
                res wholeAgain(this, "couldn't add before scope")
                return Response OK
            }

            seq := CommaSequence new(token)
            if(!trail peek() replace(this, seq)) {
                if(res fatal) res throwError(CouldntReplace new(token, this, seq, trail))
                // FIXME: what if we already added the vDecl?
                res wholeAgain(this, "couldn't unwrap")
                return Response OK
            }

            // only modify ourselves if we could do the other modifications
            varAcc := VariableAccess new(vDecl, token)
            returnArgs add(varAcc)

            seq getBody() add(this)
            seq getBody() add(varAcc)

            res wholeAgain(this, "just unwrapped")
        }

        return Response OK

    }

    /**
     * In some cases, a generic function call needs to be unwrapped,
     * e.g. when it's used as an expression in another call, etc.
     * However, some nodes are 'friendly' parents to us, e.g.
     * they handle things themselves and we don't need to unwrap.
     * @return true if the node is friendly, false if it is not and we
     * need to unwrap
     */
    isFriendlyHost: func (node: Node) -> Bool {
        node isScope() ||
        node instanceOf?(CommaSequence) ||
        node instanceOf?(VariableDecl) ||
        (node instanceOf?(BinaryOp) && node as BinaryOp type == OpType ass)
    }

    /**
     * Attempt to resolve the *actual* return type of the call, as oppposed
     * to the declared return type of our reference (a function decl).
     *
     * Mostly usefeful when the
     */
    resolveReturnType: func (trail: Trail, res: Resolver) -> Response {

        if(returnType != null) return Response OK

        //printf("Resolving returnType of %s (=%s), returnType of ref = %s, isGeneric() = %s, ref of returnType of ref = %s\n", toString(), returnType ? returnType toString() : "(nil)",
        //    ref returnType toString(), ref returnType isGeneric() toString(), ref returnType getRef() ? ref returnType getRef() toString() : "(nil)")

        if(returnType == null && ref != null) {
            if(!ref returnType isResolved()) {
                res wholeAgain(this, "need resolve the return type of our ref to see if it's generic")
                return Response OK
            }

            finalScore := 0
            if(ref returnType isGeneric()) {
                if(res params veryVerbose) printf("\t$$$$ resolving returnType %s for %s\n", ref returnType toString() toCString(), toString() toCString())
                returnType = resolveTypeArg(ref returnType getName(), trail, finalScore&)
                if((finalScore == -1 || returnType == null) && res fatal) {
                    res throwError(InternalError new(token, "Not enough info to resolve return type %s of function call\n" cformat(ref returnType toString() toCString())))
                }
            } else {
                returnType = ref returnType clone()
                returnType resolve(trail, res)
            }

            if(returnType != null && !realTypize(returnType, trail, res)) {
                res wholeAgain(this, "because couldn't properly realTypize return type.")
                returnType = null
            }
            if(returnType != null) {
                if(debugCondition()) printf("Realtypized return of %s = %s, isResolved = %s ?\n", toString() toCString(), returnType toString() toCString(), returnType isResolved() toString() toCString())
            }

            if(returnType) {
                if(debugCondition()) {
                    printf("Determined return type of %s (whose ref rt is %s) to be %s\n", toString() toCString(), ref getReturnType() toString() toCString(), returnType toString() toCString())
                    if(expr) printf("expr = %s, type = %s\n", expr toString() toCString(), expr getType() ? expr getType() toString() toCString() : "(nil)" toCString())
                }
                res wholeAgain(this, "because of return type")
                return Response OK
            }
        }

        if(returnType == null) {
            if(res fatal) res throwError(InternalError new(token, "Couldn't resolve return type of function %s\n" cformat(toString() toCString())))
            return Response LOOP
        }

        //"At the end of resolveReturnType(), the return type of %s is %s" format(toString(), getType() ? getType() toString() : "(nil)") println()
        return Response OK

    }

    realTypize: func (type: Type, trail: Trail, res: Resolver) -> Bool {

        if(debugCondition()) printf("[realTypize] realTypizing type %s in %s\n", type toString() toCString(), toString() toCString())

        if(type instanceOf?(BaseType) && type as BaseType typeArgs != null) {
            baseType := type as BaseType
            j := 0
            for(typeArg in baseType typeArgs) {
                if(debugCondition())  printf("[realTypize] for typeArg %s (ref = %s)\n", typeArg toString() toCString(), typeArg getRef() ? typeArg getRef() toString() toCString() : "(nil)" toCString())
                if(typeArg getRef() == null) {
                    return false // must resolve it before
                }
                if(debugCondition())  printf("[realTypize] Ref of typeArg %s is a %s (and expr is a %s)\n", typeArg toString() toCString(), typeArg getRef() class name toCString(), expr ? expr toString() toCString() : "(nil)" toCString())

                // if it's generic-unspecific, it needs to be resolved
                if(typeArg getRef() instanceOf?(VariableDecl)) {
                    typeArgName := typeArg getRef() as VariableDecl getName()
                    finalScore := 0
                    result := resolveTypeArg(typeArgName, trail, finalScore&)
                    if(finalScore == -1) return false
                    if(debugCondition()) printf("[realTypize] result = %s\n", result ? result toString() toCString() : "(nil)" toCString())
                    if(result) baseType typeArgs set(j, VariableAccess new(result, typeArg token))
                }
                j += 1
            }
        }

        return true

    }

    /**
     * Add casts for interfaces arguments
     */
    handleInterfaces: func (trail: Trail, res: Resolver) -> Response {

        i := 0
        for(declArg in ref args) {
            if(declArg instanceOf?(VarArg)) break
            if(i >= args getSize()) break
            callArg := args get(i)
            if(declArg getType() == null || declArg getType() getRef() == null ||
               callArg getType() == null || callArg getType() getRef() == null) {
                res wholeAgain(this, "To resolve interface-args, need to resolve declArg and callArg")
                return Response OK
            }
            if(declArg getType() getRef() instanceOf?(InterfaceDecl)) {
                if(!declArg getType() equals?(callArg getType())) {
                    args set(i, Cast new(callArg, declArg getType(), callArg token))
                }

            }
            i += 1
        }

        return Response OK

    }

    /**
     * Resolve optional arguments, ie. fill in default values
     */
    handleOptargs: func (trail: Trail, res: Resolver) -> Response {
        if(ref args size <= args size) return Response OK

        for(i in args size..ref args size) {
            refArg := ref args[i]
            // use the default value as an argument expression.
            if(refArg expr) args add(refArg expr)
        }

        Response OK
    }

    /**
     * Resolve ooc variable arguments
     */
    handleVarargs: func (trail: Trail, res: Resolver) -> Response {

        if(ref args empty?()) return Response OK

        match (lastArg := ref args last()) {
            case vararg: VarArg =>
                if(vararg name != null) {
                    numVarArgs := (args size - (ref args size - 1))

                    if(args last() getType() getName() == "VarArgs") {
                        return Response OK
                    }

                    ast := AnonymousStructType new(token)
                    elements := ArrayList<Expression> new()
                    for(i in (ref args size - 1)..(args size)) {
                        arg := args[i]
                        elements add(TypeAccess new(arg getType(), token))
                        ast types add(NullLiteral type)

                        elements add(arg)
                        ast types add(arg getType())
                    }
                    argsSl := StructLiteral new(ast, elements, token)
                    argsDecl := VariableDecl new(null, generateTempName("__va_args"), argsSl, token)
                    if(!trail addBeforeInScope(this, argsDecl)) {
                        res throwError(CouldntAddBeforeInScope new(token, this, argsDecl, trail))
                    }

                    vaType := BaseType new("VarArgs", token)
                    elements2 := [
                        AddressOf new(VariableAccess new(argsDecl, token), token)
                        NullLiteral new(token)
                        IntLiteral new(numVarArgs, token)
                    ] as ArrayList<Expression>

                    varargsSl := StructLiteral new(vaType, elements2, token)
                    vaDecl := VariableDecl new(null, generateTempName("__va"), varargsSl, token)
                    if(!trail addBeforeInScope(this, vaDecl)) {
                        res throwError(CouldntAddBeforeInScope new(token, this, vaDecl, trail))
                    }
                    numVarArgs times(||
                        args removeAt(args lastIndex())
                    )
                    args add(VariableAccess new(vaDecl, token))
                }
        }

        Response OK

    }

    /**
     * Resolve type arguments
     */
    handleGenerics: func (trail: Trail, res: Resolver) -> Response {

        j := 0
        for(implArg in ref args) {
            if(implArg instanceOf?(VarArg)) { j += 1; continue }
            implType := implArg getType()

            if(implType == null || !implType isResolved()) {
                res wholeAgain(this, "need impl arg type"); break // we'll do it later
            }
            if(!implType isGeneric() || implType pointerLevel() > 0) { j += 1; continue }

            //printf(" >> Reviewing arg %s in call %s\n", arg toString(), toString())

            callArg := args get(j)
            typeResult := callArg getType()
            if(typeResult == null) {
                res wholeAgain(this, "null callArg, need to resolve it first.")
                return Response OK
            }

            isGood := ((callArg instanceOf?(AddressOf) && callArg as AddressOf isForGenerics) || typeResult isGeneric())
            if(!isGood) { // FIXME this is probably wrong - what if we want an address's address? etc.
                target : Expression = callArg
                if(!callArg isReferencable()) {
                    varDecl := VariableDecl new(typeResult, generateTempName("genArg"), callArg, nullToken)
                    if(!trail addBeforeInScope(this, varDecl)) {
                        printf("Couldn't add %s before %s, parent is a %s\n", varDecl toString() toCString(), toString() toCString(), trail peek() toString() toCString())
                    }
                    target = VariableAccess new(varDecl, callArg token)
                }
                addrOf := AddressOf new(target, target token)
                addrOf isForGenerics = true
                args set(j, addrOf)
            }
            j += 1
        }

        if(typeArgs getSize() == ref typeArgs getSize()) {
            return Response OK // already resolved
        }

        //if(res params veryVerbose) printf("\t$$$$ resolving typeArgs of %s (call = %d, ref = %d)\n", toString(), typeArgs getSize(), ref typeArgs getSize())
        //if(res params veryVerbose) printf("trail = %s\n", trail toString())

        i := typeArgs getSize()
        while(i < ref typeArgs getSize()) {
            typeArg := ref typeArgs get(i)
            //if(res params veryVerbose) printf("\t$$$$ resolving typeArg %s\n", typeArg name)

            finalScore := 0
            typeResult := resolveTypeArg(typeArg name, trail, finalScore&)
            if(finalScore == -1) break
            if(typeResult) {
                result := typeResult instanceOf?(FuncType) ?
                    VariableAccess new("Pointer", token) :
                    VariableAccess new(typeResult, token)
                if (typeResult isGeneric()) {
                    result setRef(null) // force re-resolution - we may not be in the correct context
                }
                typeArgs add(result)
            } else break // typeArgs must be in order

            i += 1
        }

        for(typeArg in typeArgs) {
            response := typeArg resolve(trail, res)
            if(!response ok()) {
                if(res fatal) res throwError(InternalError new(token, "Couldn't resolve typeArg %s in call %s" cformat(typeArg toString() toCString(), toString() toCString())))
                return response
            }
        }

        if(typeArgs getSize() != ref typeArgs getSize()) {
            if(res fatal) {
                res throwError(InternalError new(token, "Missing info for type argument %s. Have you forgotten to qualify %s, e.g. List<Int>?" cformat(ref typeArgs get(typeArgs getSize()) getName() toCString(), ref toString() toCString())))
            }
            res wholeAgain(this, "Looping because of typeArgs\n")
        }

        return Response OK

    }

    resolveTypeArg: func (typeArgName: String, trail: Trail, finalScore: Int@) -> Type {

        if(debugCondition()) printf("Should resolve typeArg %s in call %s\n", typeArgName toCString(), toString() toCString())

        if(ref && refScore > 0) {

            if(ref genericConstraints) for(key in ref genericConstraints getKeys()) {
                if(key getName() == typeArgName) {
                    return ref genericConstraints get(key)
                }
            }

            inFunctionTypeArgs := false
            for(typeArg in ref typeArgs) {
                if(typeArg getName() == typeArgName) {
                    inFunctionTypeArgs = true
                    break
                }
            }

            if(inFunctionTypeArgs) {
                j := 0
                for(arg in ref args) {
                    /* myFunction: func <T> (myArg: T)
                     * or:
                     * myFunction: func <T> (myArg: T[])
                     * or any level of nesting =)
                     */
                    argType := arg type
                    refCount := 0
                    while(argType instanceOf?(SugarType)) {
                        argType = argType as SugarType inner
                        refCount += 1
                    }
                    if(argType getName() == typeArgName) {
                        implArg := args get(j)
                        result := implArg getType()
                        realCount := 0
                        while(result instanceOf?(SugarType) && realCount < refCount) {
                            result = result as SugarType inner
                            realCount += 1
                        }
                        if(realCount == refCount) {
                            if(debugCondition()) printf(" >> Found arg-arg %s for typeArgName %s, returning %s\n", implArg toString() toCString(), typeArgName toCString(), result toString() toCString())
                            return result
                        }
                    }

                    /* myFunction: func <T> (myArg: Func -> T) */
                    if(argType instanceOf?(FuncType)) {
                        fType := argType as FuncType

                        if(fType returnType && fType returnType getName() == typeArgName) {
                            if(debugCondition()) " >> Hey, we have an interesting FuncType %s" cformat(fType toString() toCString()) println()
                            implArg := args get(j)
                            if(implArg instanceOf?(FunctionDecl)) {
                                fDecl := implArg as FunctionDecl
                                if(fDecl inferredReturnType) {
                                    if(debugCondition()) " >> Got it from inferred return type %s!" cformat(fDecl inferredReturnType toString() toCString()) println()
                                    return fDecl inferredReturnType
                                } else {
                                    if(debugCondition()) " >> We need the inferred return type. Looping" println()
                                    finalScore = -1
                                    return null
                                }
                            }
                        }
                    }

                    /* myFunction: func <T> (T: Class) */
                    if(arg getName() == typeArgName) {
                        implArg := args get(j)
                        match implArg {
                            case vAcc: VariableAccess =>
                                if(!vAcc getRef()) {
                                    finalScore == -1
                                    return null
                                }
                                result := BaseType new(vAcc getName(), implArg token)
                                result setRef(vAcc getRef())

                                if(debugCondition()) " >> Found ref-arg %s for typeArgName %s, returning %s" cformat(implArg toString() toCString(), typeArgName toCString(), result toString() toCString()) println()
                                return result
                            case tAcc: TypeAccess =>
                                return tAcc inner
                            case type: Type =>
                                return type
                        }
                    }
                    j += 1
                }

                /* myFunction: func <T> (myArg: OtherType<T>) */
                for(arg in args) {
                    if(arg getType() == null) continue

                    if(debugCondition()) printf("Looking for typeArg %s in arg's type %s\n", typeArgName, arg getType() toString() toCString())
                    result := arg getType() searchTypeArg(typeArgName, finalScore&)
                    if(finalScore == -1) return null // something has to be resolved further!
                    if(result) {
                        if(debugCondition()) printf("Found match for arg %s! Hence, result = %s (cause arg = %s)\n", typeArgName toCString(), result toString() toCString(), arg toString() toCString())
                        return result
                    }
                }
            }
        }

        if(expr != null) {
            if(expr instanceOf?(Type)) {
                /* Type<T> myFunction() */
                if(debugCondition()) printf("Looking for typeArg %s in expr-type %s\n", typeArgName, expr toString() toCString())
                result := expr as Type searchTypeArg(typeArgName, finalScore&)
                if(finalScore == -1) return null // something has to be resolved further!
                if(result) {
                    if(debugCondition()) printf("Found match for arg %s! Hence, result = %s (cause expr = %s)\n", typeArgName, result toString() toCString(), expr toString() toCString())
                    return result
                }
            } else if(expr getType() != null) {
                /* expr: Type<T>; expr myFunction() */
                if(debugCondition()) printf("Looking for typeArg %s in expr %s\n", typeArgName toCString(), expr toString() toCString())
                result := expr getType() searchTypeArg(typeArgName, finalScore&)
                if(finalScore == -1) return null // something has to be resolved further!
                if(result) {
                    if(debugCondition()) printf("Found match for arg %s! Hence, result = %s (cause expr type = %s)\n", typeArgName toCString(), result toString() toCString(), expr getType() toString() toCString())
                    return result
                }
            }
        }

        if(trail) {
            idx := trail find(TypeDecl)
            if(idx != -1) {
                tDecl := trail get(idx, TypeDecl)
                if(debugCondition()) "\n===\nFound tDecl %s" cformat(tDecl toString() toCString()) println()
                for(typeArg in tDecl getTypeArgs()) {
                    if(typeArg getName() == typeArgName) {
                        result := BaseType new(typeArgName, token)
                        result setRef(typeArg)
                        return result
                    }
                }

                if(tDecl getNonMeta() != null) {
                    result := tDecl getNonMeta() getInstanceType() searchTypeArg(typeArgName, finalScore&)
                    if(finalScore == -1) return null // something has to be resolved further!
                    if(result) {
                        if(debugCondition()) printf("Found in-TypeDecl match for arg %s! Hence, result = %s (cause expr type = %s)\n", typeArgName toCString(), result toString() toCString(), tDecl getNonMeta() getInstanceType() toString() toCString())
                        return result
                    }
                }
            }

            idx = trail find(FunctionDecl)
            while(idx != -1) {
                fDecl := trail get(idx, FunctionDecl)
                if(debugCondition()) "\n===\nFound fDecl %s, with %d typeArgs" cformat(fDecl toString() toCString(), fDecl getTypeArgs() getSize()) println()
                for(typeArg in fDecl getTypeArgs()) {
                    if(typeArg getName() == typeArgName) {
                        result := BaseType new(typeArgName, token)
                        result setRef(typeArg)
                        return result
                    }
                }
                idx = trail find(FunctionDecl, idx - 1)
            }
        }

        if(debugCondition()) printf("Couldn't resolve typeArg %s\n", typeArgName toCString())
        return null

    }

    /**
     * @return the score of decl, respective to this function call.
     * This is used when resolving function calls, so that the function
     * decl with the highest score is chosen as a reference.
     */
    getScore: func (decl: FunctionDecl) -> Int {
        score := 0

        declArgs := decl args
        if(matchesArgs(decl)) {
            score += Type SCORE_SEED / 4
            if(debugCondition()) {
                printf("matchesArg, score is now %d\n", score)
            }
        } else {
            if(debugCondition()) {
                printf("doesn't match args, too bad!\n", score)
            }
            return Type NOLUCK_SCORE
        }

        if(decl getOwner() != null && isMember()) {
            // Will suffice to make a member call stronger
            score += Type SCORE_SEED / 4
        }

        if(suffix == null && decl suffix == null && !decl isStatic()) {
            // even though an unsuffixed call could be a call
            // to any of the suffixed versions, if both the call
            // and the decl don't have a suffix, that's a good sign.
            score += Type SCORE_SEED / 4
        }

        if(declArgs getSize() == 0) return score

        declIter : Iterator<Argument> = declArgs iterator()
        callIter : Iterator<Expression> = args iterator()

        while(callIter hasNext?() && declIter hasNext?()) {
            declArg := declIter next()
            callArg := callIter next()
            // avoid null types
            if(declArg instanceOf?(VarArg)) break
            if(declArg getType() == null) {
                if(debugCondition()) "Score is -1 because of declArg %s\n" cformat(declArg toString() toCString()) println()
                return -1
            }
            if(callArg getType() == null) {
                if(debugCondition()) "Score is -1 because of callArg %s\n" cformat(callArg toString() toCString()) println()
                return -1
            }

            declArgType := declArg getType() refToPointer()
            if (declArgType isGeneric()) {
                declArgType = declArgType realTypize(this)
            }

            typeScore := callArg getType() getScore(declArgType)
            if(typeScore == -1) {
                if(debugCondition()) {
                    printf("-1 because of type score between %s and %s\n", callArg getType() toString() toCString(), declArgType refToPointer() toString() toCString())
                }
                return -1
            }
            if (decl isExtern()) {
                if(typeScore == Type NOLUCK_SCORE) {
                    ref := callArg getType() getRef()
                    if(ref instanceOf?(TypeDecl)) {
                        ref as TypeDecl implicitConversions each(|opdecl|
                            if(opdecl fDecl getReturnType() equals?(declArgType)) {
                                typeScore = Type SCORE_SEED / 4
                            }
                        )
                    }
                }
            }

            score += typeScore

            if(debugCondition()) {
                printf("typeScore for %s vs %s == %d    for call %s (%s vs %s) [%p vs %p]\n",
                    callArg getType() toString() toCString(), declArgType refToPointer() toString() toCString(), typeScore, toString() toCString(),
                    callArg getType() getGroundType() toString() toCString(), declArgType refToPointer() getGroundType() toString() toCString(),
                    callArg getType() getRef(), declArgType getRef())
            }
        }

        if(debugCondition()) {
            printf("Final score = %d\n", score)
        }

        return score
    }

    /**
     * Returns true if decl has a signature compatible with this function call
     */
    matchesArgs: func (decl: FunctionDecl) -> Bool {

        callIter := args iterator()
        declIter := decl args iterator()

        // deal with all the callArgs we have
        while(callIter hasNext?()) {
            if(!declIter hasNext?()) {
                if(debugCondition()) "Args don't match! Too many call args" println()
                return false
            }

            if(declIter next() instanceOf?(VarArg)) {
                if(debugCondition()) "Varargs swallow all!" println()
                // well, whatever we have left, VarArgs swallows it all.
                return true
            }

            if(debugCondition()) "Regular arg consumes one." println()
            // if not varargs, consume one callarg.
            callIter next()
        }

        // deal with remaining declArgs
        while(declIter hasNext?()) {
            declArg := declIter next()
            if(declArg instanceOf?(VarArg)) {
                if(debugCondition()) "Ending on a classy varargs." println()
                // varargs can also be omitted.
                return true
            }

            if(declArg expr) {
                // optional arg
                if(debugCondition()) "Optional arg." println()
                continue
            }
            // not an optional arg? then it's not a match, sorry m'am.
            if(debugCondition()) "Args don't match! Not enough call args" println()
            return false
        }
        true
    }

    getType: func -> Type { returnType }

    isMember: func -> Bool {
        (expr != null) &&
        !(expr instanceOf?(VariableAccess) &&
          expr as VariableAccess getRef() != null &&
          expr as VariableAccess getRef() instanceOf?(NamespaceDecl)
        )
    }

    getArgsRepr: func -> String {
        sb := Buffer new()
        sb append("(")
        isFirst := true
        for(arg in args) {
            if(!isFirst) sb append(", ")
            sb append(arg ? arg toString() : "(null)")
            if(isFirst) isFirst = false
        }
        sb append(")")
        return sb toString()
    }

    getArgsTypesRepr: func -> String {
        sb := Buffer new()
        sb append("(")
        isFirst := true
        for(arg in args) {
            if(!isFirst) sb append(", ")
            sb append(arg getType() ? arg getType() toString() : "<unknown type>")
            if(isFirst) isFirst = false
        }
        sb append(")")
        return sb toString()
    }

    toString: func -> String {
        (expr ? expr toString() + " " : "") + (ref ? ref getName() : name) + getArgsRepr()
    }

    replace: func (oldie, kiddo: Node) -> Bool {
        if(oldie == expr) {
            expr = kiddo;
            return true;
        }

        args replace(oldie as Expression, kiddo as Expression)
    }

    setReturnArg: func (retArg: Expression) {
        if(returnArgs empty?()) returnArgs add(retArg)
        else                     returnArgs[0] = retArg
    }
    getReturnArgs: func -> List<Expression> { returnArgs }

    getRef: func -> FunctionDecl { ref }
    setRef: func (=ref) { refScore = 1; /* or it'll keep trying to resolve it =) */ }

    getArguments: func ->  ArrayList<Expression> { args }

}


/**
 * Error thrown when a type isn't defined
 */
UnresolvedCall: class extends Error {

    call: FunctionCall
    precisions: String

    init: func (.call, .message, =precisions) {
        init(call token, call, message)
    }

    init: func ~withToken(.token, =call, .message) {
        super(call expr ? call expr token enclosing(call token) : call token, message)
        precisions = ""
    }

    format: func -> String {
        token formatMessage(message, "ERROR") + precisions
    }

}

UseOfVoidExpression: class extends Error {
    init: super func ~tokenMessage
}

