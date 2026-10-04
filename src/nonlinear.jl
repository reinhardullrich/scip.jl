# Copyright (c) 2018 Felipe Serrano, Miles Lubin, Robert Schwarz, and contributors
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

# Set of allowed Julia operators (as given by MOI)
const OPS = [
    :+,       # n-ary
    :-,     # unary, binary
    :*,   # n-ary
    :/,       # unary
    :^, # binary (or INTPOWER)
    :sqrt,   # unary
    :exp,     # unary
    :log,     # unary
    :abs,     # unary
]

const UNARY_OPS_LOOKUP = (
    exp=SCIPcreateExprExp,
    log=SCIPcreateExprLog,
    abs=SCIPcreateExprAbs,
    cos=SCIPcreateExprCos,
    sin=SCIPcreateExprSin,
)

# The accepted literal types are explicit in the compiled expression language.
Base.@nospecializeinfer function _constant_number(@nospecialize(x))::Float64
    if x isa Union{Float16,Float32,Float64}
        return Float64(x)
    elseif x isa Union{Bool,Int8,UInt8}
        return Float64(x)
    elseif x isa Union{Int16,UInt16,Int32}
        return Float64(x)
    elseif x isa Union{UInt32,Int64,UInt64}
        return Float64(x)
    elseif x isa Union{Int128,UInt128,BigInt}
        return Float64(x)
    elseif x isa Union{BigFloat,Rational{Int},Rational{BigInt}}
        return Float64(x)
    end
    throw(ArgumentError("Unsupported literal in nonlinear expression"))
end

Base.@nospecializeinfer function _constant_expression(@nospecialize(x))::Float64
    x isa Expr || return _constant_number(x)
    Meta.isexpr(x, :call) || error("Unsupported constant expression")
    op = x.args[1]::Symbol
    args = Float64[_constant_expression(a) for a in x.args[2:end]]
    n = length(args)
    if op === :+
        n >= 1 || error("Addition needs an operand")
        return sum(args)
    elseif op === :-
        n >= 1 || error("Subtraction needs an operand")
        return n == 1 ? -args[1] : args[1] - sum(args[2:end])
    elseif op === :*
        n >= 1 || error("Multiplication needs an operand")
        return prod(args)
    elseif op === :/ || op === :^
        n == 2 || error("Division and power need two operands")
        return op === :/ ? args[1] / args[2] : args[1]^args[2]
    end
    n == 1 || error("Unary operator needs one operand")
    a = args[1]
    if op === :sqrt
        return sqrt(a)
    elseif op === :exp
        return exp(a)
    elseif op === :log
        return log(a)
    elseif op === :abs
        return abs(a)
    elseif op === :sin
        return sin(a)
    elseif op === :cos
        return cos(a)
    end
    error("Unsupported constant operator; precompute the constant before constructing the expression")
end

Base.@nospecializeinfer function push_expr!(nonlin::NonlinExpr, scip::Ptr{SCIP_}, vars, @nospecialize(expr))
    if expr isa Expr
        return _push_expression!(nonlin, scip, vars, expr)
    end
    return _push_literal!(nonlin, scip, vars, _constant_number(expr))
end

function _child_pointers!(nonlin::NonlinExpr, scip::Ptr{SCIP_}, vars, args, pairs)
    children = Ptr{SCIP_EXPR}[]
    for i in eachindex(pairs)
        child, pure = pairs[i]
        if pure && child[] == C_NULL
            child, _ = _push_literal!(nonlin, scip, vars, _constant_expression(args[i+1]))
        end
        push!(children, child[])
    end
    return children
end

function _create_unary!(op::Symbol, scip, expr__, child)
    if op === :exp
        @SCIP_CALL SCIPcreateExprExp(scip, expr__, child, C_NULL, C_NULL)
    elseif op === :log
        @SCIP_CALL SCIPcreateExprLog(scip, expr__, child, C_NULL, C_NULL)
    elseif op === :abs
        @SCIP_CALL SCIPcreateExprAbs(scip, expr__, child, C_NULL, C_NULL)
    elseif op === :sin
        @SCIP_CALL SCIPcreateExprSin(scip, expr__, child, C_NULL, C_NULL)
    elseif op === :cos
        @SCIP_CALL SCIPcreateExprCos(scip, expr__, child, C_NULL, C_NULL)
    else
        error("Unsupported unary operator")
    end
    return nothing
end

"""
Extract operators from Julia expr recursively and convert to SCIP expressions.
Returns the SCIP expression pointer, whether the expression is a pure value (without variables).
"""
function _push_expression!(
    nonlin::NonlinExpr,
    scip::Ptr{SCIP_},
    vars::Dict{VarRef,<:Ref{Ptr{SCIP_VAR}}},
    expr::Expr,
)::Tuple{Base.RefValue{Ptr{SCIP_EXPR}},Bool}
    # Storage for SCIP_EXPR*
    expr__ = Ref{Ptr{SCIP_EXPR}}(C_NULL)
    num_children = length(expr.args) - 1
    pure_value = false

    if Meta.isexpr(expr, :comparison) # range constraint
        # args: [lhs, <=, mid, <=, rhs], lhs and rhs constant
        @assert length(expr.args) == 5
        @assert expr.args[2] === :<= && expr.args[4] === :<=

        # just call on middle expression, bounds are handled outside
        return push_expr!(nonlin, scip, vars, expr.args[3])

    elseif Meta.isexpr(expr, :call) # operator
        op = expr.args[1]::Symbol
        if op in (:(==), :<=, :>=)
            # args: [op, lhs, rhs], rhs constant
            @assert length(expr.args) == 3

            # just call on lhs expression, bounds are handled outside
            return push_expr!(nonlin, scip, vars, expr.args[2])

        elseif op == :^
            # Special case: power with constant exponent.
            # The Julia expression considers the base and exponent to be
            # subexpressions. SCIP does in principle support constant
            # expressions, but in the case of SCIP_EXPR_REALPOWER, the exponent
            # value is stored directly, as the second child.
            @assert num_children == 2

            # Base (first child) is proper sub-expression.
            base, pure_value = push_expr!(nonlin, scip, vars, expr.args[2])

            # Exponent (second child) is stored as value.
            @assert isa(expr.args[3], Number)
            if !pure_value
                exponent = _constant_number(expr.args[3])
                @SCIP_CALL SCIPcreateExprPow(
                    scip,
                    expr__,
                    base[],
                    exponent,
                    C_NULL,
                    C_NULL,
                )
            end
        elseif op in (:-, :+)
            @assert num_children >= 1

            if op === :- && num_children == 1
                # Special case: unary version of minus.
                # Then, insert the actual subexpression:
                right, pure_value = push_expr!(nonlin, scip, vars, expr.args[2])
                if !pure_value
                    # Finally, add the (binary) minus:
                    @SCIP_CALL SCIPcreateExprSum(
                        scip,
                        expr__,
                        Cint(1),
                        [right[]],
                        [-1.0],
                        0.0,
                        C_NULL,
                        C_NULL,
                    )
                end
            else
                coef_mul = if op === :-
                    -1.0
                else
                    1.0
                end
                subexprs_pairs = [
                    push_expr!(nonlin, scip, vars, expr.args[i+1]) for
                    i in 1:num_children
                ]
                if all(pair -> pair[2], subexprs_pairs)
                    pure_value = true
                else
                    # replace pure-value expression by its evaluated value, since no expression has been evaluated yet
                    subexprs = _child_pointers!(nonlin, scip, vars, expr.args, subexprs_pairs)
                    coefs = fill(coef_mul, num_children)
                    coefs[1] = 1.0
                    @SCIP_CALL SCIPcreateExprSum(
                        scip,
                        expr__,
                        Cint(num_children),
                        subexprs,
                        coefs,
                        0.0,
                        C_NULL,
                        C_NULL,
                    )
                    pure_value = false
                end
            end
        elseif op == :*
            @assert num_children >= 1
            subexprs_pairs = [
                push_expr!(nonlin, scip, vars, expr.args[i+1]) for
                i in 1:num_children
            ]
            if all(pair -> pair[2], subexprs_pairs)
                pure_value = true
            else
                subexprs = _child_pointers!(nonlin, scip, vars, expr.args, subexprs_pairs)
                @SCIP_CALL SCIPcreateExprProduct(
                    scip,
                    expr__,
                    num_children,
                    subexprs,
                    1.0,
                    C_NULL,
                    C_NULL,
                )
                pure_value = false
            end
        elseif op in keys(UNARY_OPS_LOOKUP)
            # Unary operators
            @assert num_children == 1
            # Insert child expression:
            child, pure_value = push_expr!(nonlin, scip, vars, expr.args[2])
            if !pure_value
                _create_unary!(op, scip, expr__, child[])
            end
        elseif op == :sqrt
            child, pure_value = push_expr!(nonlin, scip, vars, expr.args[2])
            if !pure_value
                @SCIP_CALL SCIPcreateExprPow(
                    scip,
                    expr__,
                    child[],
                    0.5,
                    C_NULL,
                    C_NULL,
                )
            end
        elseif op == :/
            @assert num_children == 2
            # Transform L / R => L * R^-1.0
            # Create left and right subexpression.
            left, pure_left = push_expr!(nonlin, scip, vars, expr.args[2])
            inverse_right_expr = :($(expr.args[3])^-1.0)
            right, pure_right =
                push_expr!(nonlin, scip, vars, inverse_right_expr)
            if pure_left && pure_right
                pure_value = true
            else
                if pure_left && expr.args[2] isa Expr
                    val = _constant_expression(expr.args[2])
                    left, _ = push_expr!(nonlin, scip, vars, val)
                end
                if pure_right
                    val = _constant_expression(inverse_right_expr)
                    right, _ = push_expr!(nonlin, scip, vars, val)
                end
                # TODO evaluate left or right
                @SCIP_CALL SCIPcreateExprProduct(
                    scip,
                    expr__,
                    num_children,
                    [left[], right[]],
                    1.0,
                    C_NULL,
                    C_NULL,
                )
            end
        else
            error("Operator not supported by SCIP.jl; precompute unsupported constant expressions")
        end

    elseif Meta.isexpr(expr, :ref) # variable
        # It should look like this:
        # :(x[MathOptInterface.VariableIndex(1)])
        @assert expr.args[1] == :x
        @assert num_children == 1
        vi = expr.args[2]::MOI.VariableIndex
        vr = VarRef(vi.value)
        v = vars[vr][]
        @SCIP_CALL SCIPcreateExprVar(scip, expr__, v, C_NULL, C_NULL)
        pure_value = false
    else
        error("Expression not supported by SCIP.jl")
    end

    if !pure_value
        # Return this expression to be referenced by parent expressions
        push!(nonlin.exprs, expr__)
    end
    return expr__, pure_value
end

function _push_literal!(
    nonlin::NonlinExpr,
    scip::Ptr{SCIP_},
    vars::Dict{VarRef,<:Ref{Ptr{SCIP_VAR}}},
    expr::Float64,
)
    # Storage for SCIP_EXPR*
    expr__ = Ref{Ptr{SCIP_EXPR}}(C_NULL)

    value = Cdouble(expr)
    @SCIP_CALL SCIPcreateExprValue(scip, expr__, value, C_NULL, C_NULL)

    @assert SCIPisExprValue(scip, expr__[]) == TRUE
    push!(nonlin.exprs, expr__)
    pure_value = true
    return expr__, pure_value
end

"""
Add nonlinear constraint to problem, return cons ref.

    lhs ≤ expression ≤ rhs

# Arguments
- `expr::Expr`: Julia expression of nonlinear function, as given by MOI.
- `lhs::Float64`: left-hand side for ranged constraint
- `rhs::Float64`: right-hand side for ranged constraint

"""
function add_nonlinear_constraint(
    scipd::SCIPData,
    expr::Expr,
    lhs::Float64,
    rhs::Float64,
)
    nonlin = NonlinExpr()

    # convert expression recursively, extract root and variable pointers
    root_expr, pure_value = try
        result = push_expr!(nonlin, scipd.scip[], scipd.vars, expr)
        result[2] && error("A nonlinear constraint must contain a variable")
        result
    catch
        _release_expressions!(scipd, nonlin)
        rethrow()
    end
    # create and add cons_nonlinear
    cons__ = Ref{Ptr{SCIP_CONS}}(C_NULL)
    @SCIP_CALL SCIPcreateConsBasicNonlinear(
        scipd,
        cons__,
        "",
        root_expr[],
        lhs,
        rhs,
    )
    @SCIP_CALL SCIPaddCons(scipd, cons__[])

    # register and return cons ref
    push!(scipd.nonlinear_storage, nonlin)
    return store_cons!(scipd, cons__)
end
