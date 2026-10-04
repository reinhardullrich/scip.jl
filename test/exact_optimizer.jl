module TestExactOptimizer
using Test
import SCIP
import MathOptInterface as MOI
const Q = Rational{BigInt}
q(n, d=1) = big(n) // big(d)
function lp(; coefficient=q(1), lower=q(0), upper=q(1), offset=q(0), sense=MOI.MIN_SENSE, integer=false, binary=false)
    m = MOI.Utilities.Model{Q}()
    x = MOI.add_variable(m)
    MOI.add_constraint(m, x, MOI.Interval(lower, upper))
    integer && MOI.add_constraint(m, x, MOI.Integer())
    binary && MOI.add_constraint(m, x, MOI.ZeroOne())
    f = MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(coefficient, x)], offset)
    MOI.set(m, MOI.ObjectiveFunction{typeof(f)}(), f)
    MOI.set(m, MOI.ObjectiveSense(), sense)
    return m, x
end
function solve(o, m, x)
    map, copied = MOI.optimize!(o, m)
    @test !copied
    @test MOI.get(o, MOI.TerminationStatus()) == MOI.OPTIMAL
    @test MOI.get(o, MOI.ResultCount()) == 1
    @test MOI.get(o, MOI.ObjectiveValue()) isa Q
    return MOI.get(o, MOI.VariablePrimal(), map[x]), MOI.get(o, MOI.ObjectiveValue())
end
@testset "Exact linear/MILP optimizer" begin
    o = SCIP.Optimizer(Q; display_verblevel=0, parallel_maxnthreads=1, lp_threads=1)
    try
        @test o isa SCIP.ExactOptimizer
        @test MOI.get(o, MOI.TerminationStatus()) == MOI.OPTIMIZE_NOT_CALLED
        @test MOI.supports_constraint(o, MOI.ScalarAffineFunction{Q}, MOI.EqualTo{Q})
        @test !MOI.supports_constraint(o, MOI.ScalarAffineFunction{Float64}, MOI.EqualTo{Float64})
        @test !MOI.supports_constraint(o, MOI.ScalarQuadraticFunction{Q}, MOI.EqualTo{Q})
        @test_throws ErrorException MOI.set(o, MOI.RawOptimizerAttribute("exact/enable"), false)
        @test_throws ErrorException MOI.set(o, MOI.RawOptimizerAttribute("limits/gap"), 1e-6)
        e = big(1)//(big(2)^80)
        for sign in (-1, 1)
            m, x = lp(coefficient=sign*e, lower=q(1), upper=q(1))
            xv, obj = solve(o, m, x)
            @test xv == 1
            @test obj == sign*e
            @test MOI.get(o, MOI.ObjectiveBound()) == obj
            @test obj isa Q
        end
        m,x = lp(lower=1+e, upper=1+e, offset=q(2,7))
        @test solve(o,m,x) == (1+e, 1+e+q(2,7))
        m,x = lp(coefficient=q(2,7), lower=q(1,3), upper=q(5,3), offset=q(2,5), sense=MOI.MAX_SENSE)
        @test solve(o,m,x) == (q(5,3),q(92,105))
        @test MOI.get(o, MOI.ObjectiveBound()) == q(92,105)
        m,x = lp(lower=q(-10), upper=q(7,3), integer=true, sense=MOI.MAX_SENSE)
        @test solve(o,m,x) == (q(2),q(2))
        m,x = lp(coefficient=-e, lower=q(0), upper=q(1), binary=true)
        @test solve(o,m,x) == (q(1),-e)
        # Rational affine rows, including a nonzero constant and repeated variable.
        m,x = lp(lower=q(-5), upper=q(5))
        f = MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(q(1,7),x),MOI.ScalarAffineTerm(q(2,7),x)],q(1,11))
        ci = MOI.add_constraint(m,f,MOI.EqualTo(q(2,11)))
        map,_ = MOI.optimize!(o,m)
        @test MOI.get(o,MOI.VariablePrimal(),map[x]) == q(7,33)
        @test MOI.get(o,MOI.ConstraintPrimal(),map[ci]) == q(2,11)
        @test_throws MOI.ResultIndexBoundsError MOI.get(o,MOI.ObjectiveValue(2))
        # Infeasible rows must not expose a solution.
        MOI.add_constraint(m,MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(q(1),x)],q(0)),MOI.GreaterThan(q(4)))
        MOI.optimize!(o,m)
        @test MOI.get(o,MOI.TerminationStatus()) == MOI.INFEASIBLE
        @test MOI.get(o,MOI.ResultCount()) == 0
        @test_throws MOI.ResultIndexBoundsError MOI.get(o,MOI.ObjectiveValue())
        # One-sided Interval rows preserve source row order without mixing sets.
        for (lo,hi,sense,want) in ((q(-1,0),q(-1,3),MOI.MAX_SENSE,q(-1,3)),
                                  (q(1,3),q(1,0),MOI.MIN_SENSE,q(1,3)))
            m,x=lp(lower=q(-5),upper=q(5),sense=sense)
            f=MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(q(1),x)],q(0))
            MOI.add_constraint(m,f,MOI.Interval(lo,hi))
            @test solve(o,m,x)==(want,want)
        end
        @test_throws ArgumentError SCIP._exact_number(o,q(1,0))
        # Unsupported data must be rejected rather than silently ignored.
        m,x = lp()
        m = MOI.Utilities.UniversalFallback(m)
        MOI.set(m, MOI.VariablePrimalStart(), x, q(1))
        @test_throws MOI.UnsupportedAttribute MOI.optimize!(o,m)
        # Feasibility-only, unbounded and contradictory-bound problems.
        m = MOI.Utilities.Model{Q}()
        x = MOI.add_variable(m)
        MOI.add_constraint(m,x,MOI.GreaterThan(q(2,7)))
        MOI.optimize!(o,m)
        @test MOI.get(o,MOI.TerminationStatus()) == MOI.OPTIMAL
        @test MOI.get(o,MOI.ObjectiveValue()) == 0
        MOI.set(m,MOI.ObjectiveSense(),MOI.MAX_SENSE)
        MOI.set(m,MOI.ObjectiveFunction{MOI.VariableIndex}(),x)
        MOI.optimize!(o,m)
        @test MOI.get(o,MOI.TerminationStatus()) == MOI.DUAL_INFEASIBLE
        @test MOI.get(o,MOI.ObjectiveBound()) == Inf
        m,x = lp(lower=q(2),upper=q(1))
        MOI.optimize!(o,m)
        @test MOI.get(o,MOI.TerminationStatus()) == MOI.INFEASIBLE
        # Zero time and repeated reset preserve settings and never imply optimality.
        MOI.set(o,MOI.TimeLimitSec(),0.0)
        m,x=lp()
        MOI.optimize!(o,m)
        @test MOI.get(o,MOI.TerminationStatus()) == MOI.TIME_LIMIT
        MOI.set(o,MOI.TimeLimitSec(),nothing)
        @test solve(o,m,x) == (q(0),q(0))
        MOI.empty!(o)
        @test MOI.is_empty(o)
        @test MOI.get(o,MOI.Silent())
        @test MOI.get(o,MOI.TerminationStatus()) == MOI.OPTIMIZE_NOT_CALLED
    finally
        SCIP._free_exact(o)
    end
end
@testset "MOI exact cached linear/MILP integration" begin
    cached = MOI.instantiate(() -> SCIP.Optimizer(Q); with_cache_type=Q)
    MOI.set(cached, MOI.Silent(), true)
    MOI.set(cached, MOI.TimeLimitSec(), 10.0)
    config = MOI.Test.Config(Q; atol=0, rtol=0, exclude=Any[
        MOI.ConstraintDual, MOI.DualObjectiveValue,
        MOI.VariableBasisStatus, MOI.ConstraintBasisStatus,
    ])
    MOI.Test.runtests(cached, config; include=[
        r"^test_linear_integration$", r"^test_linear_integer_integration$",
        r"^test_linear_integration_Interval$", r"^test_linear_FEASIBILITY_SENSE$",
    ])
end
end
