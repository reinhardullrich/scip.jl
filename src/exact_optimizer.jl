# Exact linear/MILP adapter. MIT license, as the surrounding SCIP.jl package.
# Build-at-solve deliberately avoids duplicating the incremental Float64 adapter.
const ExactRational = Rational{BigInt}
const ExactBounds = Union{MOI.EqualTo{ExactRational},MOI.LessThan{ExactRational},
                         MOI.GreaterThan{ExactRational},MOI.Interval{ExactRational}}

"""
    ExactOptimizer(; kwargs...)

SCIP 10 exact linear/MILP optimizer for `JuMP.GenericModel{Rational{BigInt}}`.
Use JuMP's normal cached model, not `direct_model`: each solve builds a fresh
native problem. Supports rational affine objectives/constraints, rational variable
bounds, and integer/binary domains. No rounded-coefficient fallback is provided.
"""
mutable struct ExactOptimizer <: MOI.AbstractOptimizer
    inner::SCIPData
    rationals::Vector{Ptr{SCIP_RATIONAL}}
    model::MOI.Utilities.Model{ExactRational}
    variables::Vector{Ptr{SCIP_VAR}}
    params::Dict{String,Union{Bool,Cint,Clonglong,Cdouble,Char,String}} # Solver options only; coefficients never enter this dictionary.
    status::MOI.TerminationStatusCode
    values::Vector{ExactRational}
    objective::Union{Nothing,ExactRational}
    bound::Union{Nothing,ExactRational,Float64} # Float64 only for +/-Inf sentinels.
    solve_time::Float64
    nodes::Int64
    iterations::Int64
    function ExactOptimizer(; kwargs...)
        o = new(SCIPData(exact=true), Ptr{SCIP_RATIONAL}[],
                MOI.Utilities.Model{ExactRational}(), Ptr{SCIP_VAR}[], Dict{String,Union{Bool,Cint,Clonglong,Cdouble,Char,String}}(),
                MOI.OPTIMIZE_NOT_CALLED, ExactRational[], nothing, nothing, 0.0, 0, 0)
        finalizer(_free_exact, o)
        try
            MOI.set(o, MOI.RawOptimizerAttribute("limits/gap"), 0.0)
            MOI.set(o, MOI.RawOptimizerAttribute("limits/absgap"), 0.0)
            for (key, value) in kwargs
                MOI.set(o, MOI.RawOptimizerAttribute(replace(string(key), "_" => "/")), value)
            end
        catch
            _free_exact(o)
            rethrow()
        end
        return o
    end
end
Optimizer(::Type{Float64}; kwargs...) = Optimizer(; kwargs...)
Optimizer(::Type{ExactRational}; kwargs...) = ExactOptimizer(; kwargs...)
Base.cconvert(::Type{Ptr{SCIP_}}, o::ExactOptimizer) = o
Base.unsafe_convert(::Type{Ptr{SCIP_}}, o::ExactOptimizer) = o.inner.scip[]

function _free_exact(o::ExactOptimizer)
    free_scip(o.inner) # Native constraints may still reference the rational data.
    for p in o.rationals
        SCIPrationalFree(Ref(p))
    end
    empty!(o.rationals)
    empty!(o.variables)
    return nothing
end

function MOI.empty!(o::ExactOptimizer)
    _free_exact(o)
    MOI.empty!(o.model)
    empty!(o.values)
    o.objective = nothing
    o.bound = nothing
    o.status = MOI.OPTIMIZE_NOT_CALLED
    o.solve_time = 0.0
    o.nodes = o.iterations = 0
    o.inner = SCIPData(exact=true)
    for (name, value) in o.params
        set_parameter(o.inner, name, value)
    end
    return nothing
end
MOI.is_empty(o::ExactOptimizer) = MOI.is_empty(o.model)
MOI.supports_incremental_interface(::ExactOptimizer) = false
MOI.get(::ExactOptimizer, ::MOI.SolverName) = "SCIP exact"
MOI.get(::ExactOptimizer, ::MOI.SolverVersion) = string(SCIP_versionnumber())
MOI.supports_constraint(::ExactOptimizer, ::Type{MOI.VariableIndex},
                       ::Type{<:Union{ExactBounds,MOI.Integer,MOI.ZeroOne}}) = true
MOI.supports_constraint(::ExactOptimizer, ::Type{MOI.ScalarAffineFunction{ExactRational}},
                       ::Type{<:ExactBounds}) = true
MOI.supports(::ExactOptimizer, ::MOI.ObjectiveSense) = true
MOI.supports(::ExactOptimizer, ::MOI.ObjectiveFunction{MOI.VariableIndex}) = true
MOI.supports(::ExactOptimizer, ::MOI.ObjectiveFunction{MOI.ScalarAffineFunction{ExactRational}}) = true
MOI.supports(::ExactOptimizer, ::MOI.Name) = true
MOI.supports(::ExactOptimizer, ::MOI.VariableName, ::Type{MOI.VariableIndex}) = true
MOI.supports(::ExactOptimizer, ::MOI.ConstraintName, ::Type{<:MOI.ConstraintIndex}) = true
MOI.supports(::ExactOptimizer, ::MOI.RawOptimizerAttribute) = true
MOI.get(o::ExactOptimizer, a::MOI.RawOptimizerAttribute) = get_parameter(o.inner, a.name)
function MOI.set(o::ExactOptimizer, a::MOI.RawOptimizerAttribute, value)
    # Exactness is a constructor-level capability, never a mutable solver option.
    startswith(a.name, "exact/") && error("Exact-mode options are managed by ExactOptimizer")
    a.name in ("limits/gap", "limits/absgap") && value != 0 &&
        error("ExactOptimizer requires zero relative and absolute gaps")
    set_parameter(o.inner, a.name, value)
    o.params[a.name] = get_parameter(o.inner, a.name)
    return nothing
end
MOI.supports(::ExactOptimizer, ::MOI.Silent) = true
MOI.get(o::ExactOptimizer, ::MOI.Silent) = get_parameter(o.inner, "display/verblevel") == 0
MOI.set(o::ExactOptimizer, ::MOI.Silent, value::Bool) =
    MOI.set(o, MOI.RawOptimizerAttribute("display/verblevel"), value ? 0 : 4)
MOI.supports(::ExactOptimizer, ::MOI.TimeLimitSec) = true
function MOI.set(o::ExactOptimizer, ::MOI.TimeLimitSec, value::Union{Nothing,Real})
    value !== nothing && (!isfinite(value) || value < 0) && error("Invalid time limit")
    return MOI.set(o, MOI.RawOptimizerAttribute("limits/time"), value === nothing ? 1e20 : Float64(value))
end
function MOI.get(o::ExactOptimizer, ::MOI.TimeLimitSec)
    value = get_parameter(o.inner, "limits/time")
    return value >= SCIPinfinity(o) ? nothing : value
end

# Text transfer is exact numerator/denominator transfer, never Float64 conversion.
function _exact_number(o::ExactOptimizer, x::ExactRational)::Ptr{SCIP_RATIONAL}
    isfinite(x) || throw(ArgumentError("Model coefficients and finite bounds must be finite rationals"))
    p = Ref{Ptr{SCIP_RATIONAL}}(C_NULL)
    @SCIP_CALL SCIPrationalCreate(p)
    try
        push!(o.rationals, p[])
    catch
        SCIPrationalFree(p)
        rethrow()
    end
    SCIPrationalSetString(p[], string(numerator(x), "/", denominator(x)))
    return p[]
end
function _exact_infinity(o::ExactOptimizer, negative::Bool)::Ptr{SCIP_RATIONAL}
    p = _exact_number(o, zero(ExactRational))
    negative ? SCIPrationalSetNegInfinity(p) : SCIPrationalSetInfinity(p)
    return p
end
function _read_exact(p::Ptr{SCIP_RATIONAL})::ExactRational
    (SCIPrationalIsInfinity(p) != 0 || SCIPrationalIsNegInfinity(p) != 0) && error("Nonfinite rational result")
    n = SCIPrationalStrLen(p)
    0 <= n < typemax(Cint) || error("Invalid rational string size")
    bytes = Vector{UInt8}(undef, n + 1)
    copied = SCIPrationalToString(p, bytes, length(bytes))
    0 <= copied <= n || error("Truncated rational result")
    text = String(bytes[1:copied])
    parts = split(text, '/')
    return length(parts) == 1 ? parse(BigInt, parts[1]) // big(1) :
                               parse(BigInt, parts[1]) // parse(BigInt, parts[2])
end
_exact_sides(s::MOI.EqualTo{ExactRational}) = (s.value, s.value)
_exact_sides(s::MOI.LessThan{ExactRational}) = (nothing, s.upper)
_exact_sides(s::MOI.GreaterThan{ExactRational}) = (s.lower, nothing)
function _exact_sides(s::MOI.Interval{ExactRational})
    # Infinite interval endpoints are bounds, never finite model coefficients.
    lo = isinf(s.lower) && s.lower < 0 ? nothing : s.lower
    hi = isinf(s.upper) && s.upper > 0 ? nothing : s.upper
    return lo, hi
end

function _exact_objective(model)::MOI.ScalarAffineFunction{ExactRational}
    if MOI.get(model, MOI.ObjectiveSense()) == MOI.FEASIBILITY_SENSE
        return MOI.ScalarAffineFunction(MOI.ScalarAffineTerm{ExactRational}[], zero(ExactRational))
    end
    F = MOI.get(model, MOI.ObjectiveFunctionType())
    f = MOI.get(model, MOI.ObjectiveFunction{F}())
    return MOI.Utilities.convert_approx(MOI.ScalarAffineFunction{ExactRational}, f)
end

function _build_exact(o::ExactOptimizer)
    model = o.model
    n = MOI.get(model, MOI.NumberOfVariables())
    n <= typemax(Cint) || error("Too many variables for SCIP")
    objective = _exact_objective(model)
    coefficients = zeros(ExactRational, n)
    for term in objective.terms
        coefficients[term.variable.value] += term.coefficient
    end
    lower = Union{Nothing,ExactRational}[nothing for _ in 1:n]
    upper = copy(lower)
    types = fill(SCIP_VARTYPE_CONTINUOUS, n)
    for (F, S) in MOI.get(model, MOI.ListOfConstraintTypesPresent())
        F == MOI.VariableIndex || continue
        for ci in MOI.get(model, MOI.ListOfConstraintIndices{F,S}())
            i = MOI.get(model, MOI.ConstraintFunction(), ci).value
            s = MOI.get(model, MOI.ConstraintSet(), ci)
            if s isa MOI.ZeroOne
                types[i] = SCIP_VARTYPE_BINARY
                lo, hi = zero(ExactRational), one(ExactRational)
            elseif s isa MOI.Integer
                types[i] == SCIP_VARTYPE_BINARY || (types[i] = SCIP_VARTYPE_INTEGER)
                continue
            else
                lo, hi = _exact_sides(s)
            end
            lo !== nothing && (lower[i] = lower[i] === nothing ? lo : max(lower[i], lo))
            hi !== nothing && (upper[i] = upper[i] === nothing ? hi : min(upper[i], hi))
        end
    end
    neginf, posinf = _exact_infinity(o, true), _exact_infinity(o, false)
    for i in 1:n
        lb = lower[i] === nothing ? neginf : _exact_number(o, lower[i])
        ub = upper[i] === nothing ? posinf : _exact_number(o, upper[i])
        obj = _exact_number(o, coefficients[i])
        v = Ref{Ptr{SCIP_VAR}}(C_NULL)
        # SCIP needs approximate bootstrap data as well as authoritative exact data.
        @SCIP_CALL SCIPcreateVarBasic(o, v, "x_$i", SCIPrationalGetReal(lb),
                                     SCIPrationalGetReal(ub), SCIPrationalGetReal(obj), types[i])
        try
            @SCIP_CALL SCIPaddVarExactData(o, v[], lb, ub, obj)
            @SCIP_CALL SCIPaddVar(o, v[])
            push!(o.variables, v[])
        finally
            @SCIP_CALL SCIPreleaseVar(o, v)
        end
    end
    # The objective constant is added exactly when returning objective/bound values.
    sense = MOI.get(model, MOI.ObjectiveSense())
    @SCIP_CALL SCIPsetObjsense(o, sense == MOI.MAX_SENSE ? SCIP_OBJSENSE_MAXIMIZE : SCIP_OBJSENSE_MINIMIZE)
    for (F, S) in MOI.get(model, MOI.ListOfConstraintTypesPresent())
        F == MOI.ScalarAffineFunction{ExactRational} || continue
        _build_exact_rows(o, F, S, neginf, posinf)
    end
    return nothing
end

# Function barrier specializes the row loop for each concrete constraint type.
function _build_exact_rows(o::ExactOptimizer, ::Type{F}, ::Type{S}, neginf, posinf) where {F,S}
    for ci in MOI.get(o.model, MOI.ListOfConstraintIndices{F,S}())
        f = MOI.get(o.model, MOI.ConstraintFunction(), ci)
        s = MOI.get(o.model, MOI.ConstraintSet(), ci)
        lo, hi = _exact_sides(s)
        lb = lo === nothing ? neginf : _exact_number(o, lo - f.constant)
        ub = hi === nothing ? posinf : _exact_number(o, hi - f.constant)
        vars = Ptr{SCIP_VAR}[o.variables[t.variable.value] for t in f.terms]
        vals = Ptr{SCIP_RATIONAL}[_exact_number(o, t.coefficient) for t in f.terms]
        length(vars) <= typemax(Cint) || error("Too many row coefficients")
        cons = Ref{Ptr{SCIP_CONS}}(C_NULL)
        @SCIP_CALL SCIPcreateConsBasicExactLinear(o, cons, "row_$(ci.value)", length(vars), vars, vals, lb, ub)
        try
            @SCIP_CALL SCIPaddCons(o, cons[])
        finally
            @SCIP_CALL SCIPreleaseCons(o, cons)
        end
    end
    return nothing
end

_exact_value(f::MOI.VariableIndex, x::Vector{ExactRational}) = x[f.value]
function _exact_value(f::MOI.ScalarAffineFunction{ExactRational}, x::Vector{ExactRational})
    result = f.constant
    for t in f.terms
        result += t.coefficient * x[t.variable.value]
    end
    return result
end
_exact_member(x::ExactRational, ::MOI.Integer) = denominator(x) == 1
_exact_member(x::ExactRational, ::MOI.ZeroOne) = x == 0 || x == 1
function _exact_member(x::ExactRational, s::ExactBounds)
    lo, hi = _exact_sides(s)
    return (lo === nothing || x >= lo) && (hi === nothing || x <= hi)
end
function _verify_exact_rows(model, x, ::Type{F}, ::Type{S}) where {F,S}
    for ci in MOI.get(model, MOI.ListOfConstraintIndices{F,S}())
        f = MOI.get(model, MOI.ConstraintFunction(), ci)
        s = MOI.get(model, MOI.ConstraintSet(), ci)
        _exact_member(_exact_value(f, x), s) || error("SCIP solution fails exact primal feasibility")
    end
    return nothing
end

function MOI.optimize!(o::ExactOptimizer, source::MOI.ModelLike)
    started = time_ns()
    MOI.empty!(o)
    for attr in MOI.get(source, MOI.ListOfModelAttributesSet())
        MOI.supports(o, attr) || throw(MOI.UnsupportedAttribute(attr))
    end
    for attr in MOI.get(source, MOI.ListOfVariableAttributesSet())
        MOI.supports(o, attr, MOI.VariableIndex) || throw(MOI.UnsupportedAttribute(attr))
    end
    for (F, S) in MOI.get(source, MOI.ListOfConstraintTypesPresent())
        MOI.supports_constraint(o, F, S) || throw(MOI.UnsupportedConstraint{F,S}())
        for attr in MOI.get(source, MOI.ListOfConstraintAttributesSet{F,S}())
            MOI.supports(o, attr, MOI.ConstraintIndex{F,S}) || throw(MOI.UnsupportedAttribute(attr))
        end
    end
    F = MOI.get(source, MOI.ObjectiveFunctionType())
    MOI.supports(o, MOI.ObjectiveFunction{F}()) || throw(MOI.UnsupportedAttribute(MOI.ObjectiveFunction{F}()))
    map = MOI.copy_to(o.model, source)
    try
        _build_exact(o)
        # Model transfer is part of the caller's remaining budget. Request the
        # native timeout immediately before entering SCIP, without callbacks.
        budget = get_parameter(o.inner, "limits/time")
        if budget < 1e20
            remaining = budget - (time_ns() - started) / 1e9
            if remaining <= 0
                o.status = MOI.TIME_LIMIT
                return map, false
            end
            set_parameter(o.inner, "limits/time", remaining)
        end
        @SCIP_CALL SCIPsolve(o)
        SCIPisExact(o) != 0 || error("SCIP left exact solving mode")
        status = SCIPgetStatus(o)
        o.status = status == SCIP_STATUS_GAPLIMIT ? MOI.OTHER_LIMIT : _TERMINATION_STATUS_MAP[status]
        o.solve_time = SCIPgetSolvingTime(o)
        o.nodes = SCIPgetNNodes(o)
        o.iterations = SCIPgetNLPIterations(o)
        value = _exact_number(o, zero(ExactRational))
        SCIPgetDualboundExact(o, value)
        offset = _exact_objective(o.model).constant
        o.bound = SCIPrationalIsInfinity(value) != 0 ? Inf :
                  SCIPrationalIsNegInfinity(value) != 0 ? -Inf : _read_exact(value) + offset
        sol = SCIPgetBestSol(o)
        if sol != C_NULL && status ∉ (SCIP_STATUS_UNBOUNDED, SCIP_STATUS_INFORUNBD)
            for v in o.variables
                SCIPgetSolValExact(o, sol, v, value)
                push!(o.values, _read_exact(value))
            end
            for (F, S) in MOI.get(o.model, MOI.ListOfConstraintTypesPresent())
                _verify_exact_rows(o.model, o.values, F, S)
            end
            SCIPgetSolOrigObjExact(o, sol, value)
            o.objective = _read_exact(value) + offset
            _exact_value(_exact_objective(o.model), o.values) == o.objective || error("Exact objective mismatch")
        end
        if o.status == MOI.OPTIMAL
            o.objective !== nothing && o.objective == o.bound || error("Exact primal and dual bounds disagree")
        end
    catch
        empty!(o.values)
        o.objective = o.bound = nothing
        o.status = MOI.OTHER_ERROR
        rethrow()
    end
    return map, false
end
MOI.get(o::ExactOptimizer, ::MOI.TerminationStatus) = o.status
MOI.get(o::ExactOptimizer, ::MOI.RawStatusString) = string(o.status)
MOI.get(o::ExactOptimizer, ::MOI.ResultCount) = o.objective === nothing ? 0 : 1
MOI.get(o::ExactOptimizer, a::MOI.PrimalStatus) = a.result_index == 1 && o.objective !== nothing ? MOI.FEASIBLE_POINT : MOI.NO_SOLUTION
MOI.get(::ExactOptimizer, ::MOI.DualStatus) = MOI.NO_SOLUTION
function MOI.get(o::ExactOptimizer, a::MOI.VariablePrimal, v::MOI.VariableIndex)
    MOI.check_result_index_bounds(o, a)
    MOI.is_valid(o.model, v) || throw(MOI.InvalidIndex(v))
    return o.values[v.value]
end
function MOI.get(o::ExactOptimizer, a::MOI.ObjectiveValue)
    MOI.check_result_index_bounds(o, a)
    return o.objective::ExactRational
end
function MOI.get(o::ExactOptimizer, ::MOI.ObjectiveBound)
    o.bound === nothing && error("No objective bound is available")
    return o.bound
end
function MOI.get(o::ExactOptimizer, a::MOI.ConstraintPrimal, ci::MOI.ConstraintIndex)
    MOI.check_result_index_bounds(o, a)
    return _exact_value(MOI.get(o.model, MOI.ConstraintFunction(), ci), o.values)
end
MOI.get(o::ExactOptimizer, ::MOI.SolveTimeSec) = o.solve_time
MOI.get(o::ExactOptimizer, ::MOI.NodeCount) = o.nodes
MOI.get(o::ExactOptimizer, ::MOI.SimplexIterations) = o.iterations
