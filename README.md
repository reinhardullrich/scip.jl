# SCIP.jl

[![Build Status](https://github.com/scipopt/SCIP.jl/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/scipopt/SCIP.jl/actions?query=workflow%3ACI)
[![codecov](https://codecov.io/gh/scipopt/SCIP.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/scipopt/SCIP.jl)

[SCIP.jl](https://github.com/scipopt/SCIP.jl) is a Julia interface to the
[SCIP](https://scipopt.org) solver.

It has two components:

 - a thin wrapper around the complete C API
 - an interface to [MathOptInterface](https://github.com/jump-dev/MathOptInterface.jl)

## Affiliation

This wrapper is maintained by the [SCIP project](https://www.scipopt.org/) with
the help of the JuMP community.

## Getting help

If you need help, please ask a question on the [JuMP community forum](https://jump.dev/forum).

If you have a reproducible example of a bug, please [open a GitHub issue](https://github.com/scipopt/SCIP.jl/issues/new).

## License

`SCIP.jl` is licensed under the [MIT License](https://github.com/scipopt/SCIP.jl/blob/master/LICENSE).

The underlying solver, [scipopt/scip](https://github.com/scipopt/scip), is
licensed under the [Apache 2.0 license](https://github.com/scipopt/scip/blob/master/LICENSE).

## Installation

Install SCIP using `Pkg.add`:
```julia
julia> import Pkg

julia> Pkg.add("SCIP")
```

In addition to installing the SCIP.jl package, this will also download and
install the SCIP binaries. You do not need to install SCIP separately.

## Custom installations

If you want a custom SCIP installation, you must manually install the SCIP
binaries.

Binaries are available for download at [https://www.scipopt.org/#download](https://www.scipopt.org/#download).

Once the binaries are installed, set the `SCIPOPTDIR` environment variable to
temporarily point to the installation path (that is, depending on your operating
system, `$SCIPOPTDIR/lib/libscip.so`, `$SCIPOPTDIR/lib/libscip.dylib`, or
`$SCIPOPTDIR/bin/libscip.dll` must exist). Then, install `SCIP.jl` using `Pkg.add`
and `Pkg.build` from the Julia command line:
```julia
julia> ENV["SCIPOPTDIR"] = raw"C:\Program Files\SCIPOptSuite 9.1.1" # for Windows

julia> import Pkg

julia> Pkg.add("SCIP")

julia> Pkg.build("SCIP")
```

## Use with JuMP

Use SCIP with JuMP as follows:

```julia
using JuMP, SCIP
model = Model(SCIP.Optimizer)
set_attribute(model, "display/verblevel", 0)
set_attribute(model, "limits/gap", 0.05)
```

## Options

### Experimental exact linear/MILP support in this fork

The arithmetic type can be chosen at construction. `Optimizer()` and
`Optimizer(Float64)` retain the existing numerical adapter. With a SCIP 10
library built with exact-solving support:

```julia
using JuMP, SCIP
const Q = Rational{BigInt}
model = GenericModel{Q}(() -> SCIP.Optimizer(Q); add_bridges = false)
set_silent(model)
@variable(model, x >= 1//3)
@objective(model, Min, 2//7 * x + 2//5)
optimize!(model)
@assert value(x) == big(1)//3
@assert objective_value(model) == big(52)//105
```

`Optimizer(Q)` constructs the concrete `ExactOptimizer` adapter. It supports
rational affine objectives and constraints, variable bounds, and integer/binary
domains. It builds a fresh native problem on each solve, using SCIP's exact
variable data and exact linear constraints. Every returned primal point is
checked against the original rational constraints, domains and objective; an
optimal result also requires equal exact primal and dual bounds. Numerators
and denominators are transferred losslessly through SCIP's rational API.
SCIP itself uses both approximate and exact calculations internally.

Use the normal cached JuMP model. Direct/incremental mode, quadratic/nonlinear
constraints, callbacks, starts, dual multipliers and infeasibility/unboundedness
certificates are not implemented by this adapter. Unsupported input is rejected;
there is no numerical fallback. Model edits in the JuMP cache take effect on the
next solve. Exact-mode options and nonzero optimality gaps cannot be enabled
through the adapter. Finite results use `Rational{BigInt}`; an unbounded objective
bound uses an infinity sentinel.

Custom libraries use the existing `SCIPOPTDIR` / `Pkg.build("SCIP")` workflow
above. Selecting the native library is independent of the arithmetic choice.
This extension is experimental and has not been accepted upstream.

See the [SCIP documentation](https://www.scipopt.org/doc/html/PARAMETERS.php)
for a list of supported options.

## MathOptInterface API

The SCIP optimizer supports the following constraints and attributes.

List of supported objective functions:

 * [`MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}`](@ref)

List of supported variable types:

 * [`MOI.Reals`](@ref)

List of supported constraint types:

 * [`MOI.ScalarAffineFunction{Float64}`](@ref) in [`MOI.EqualTo{Float64}`](@ref)
 * [`MOI.ScalarAffineFunction{Float64}`](@ref) in [`MOI.GreaterThan{Float64}`](@ref)
 * [`MOI.ScalarAffineFunction{Float64}`](@ref) in [`MOI.Interval{Float64}`](@ref)
 * [`MOI.ScalarAffineFunction{Float64}`](@ref) in [`MOI.LessThan{Float64}`](@ref)
 * [`MOI.ScalarNonlinearFunction`](@ref) in [`MOI.EqualTo{Float64}`](@ref)
 * [`MOI.ScalarNonlinearFunction`](@ref) in [`MOI.GreaterThan{Float64}`](@ref)
 * [`MOI.ScalarNonlinearFunction`](@ref) in [`MOI.Interval{Float64}`](@ref)
 * [`MOI.ScalarNonlinearFunction`](@ref) in [`MOI.LessThan{Float64}`](@ref)
 * [`MOI.ScalarQuadraticFunction{Float64}`](@ref) in [`MOI.EqualTo{Float64}`](@ref)
 * [`MOI.ScalarQuadraticFunction{Float64}`](@ref) in [`MOI.GreaterThan{Float64}`](@ref)
 * [`MOI.ScalarQuadraticFunction{Float64}`](@ref) in [`MOI.Interval{Float64}`](@ref)
 * [`MOI.ScalarQuadraticFunction{Float64}`](@ref) in [`MOI.LessThan{Float64}`](@ref)
 * [`MOI.VariableIndex`](@ref) in [`MOI.EqualTo{Float64}`](@ref)
 * [`MOI.VariableIndex`](@ref) in [`MOI.GreaterThan{Float64}`](@ref)
 * [`MOI.VariableIndex`](@ref) in [`MOI.Integer`](@ref)
 * [`MOI.VariableIndex`](@ref) in [`MOI.Interval{Float64}`](@ref)
 * [`MOI.VariableIndex`](@ref) in [`MOI.LessThan{Float64}`](@ref)
 * [`MOI.VariableIndex`](@ref) in [`MOI.ZeroOne`](@ref)
 * [`MOI.VectorAffineFunction{Float64}`](@ref) in [`MOI.Indicator{MOI.ACTIVATE_ON_ONE,MOI.LessThan{Float64}}`](@ref)
 * [`MOI.VectorOfVariables`](@ref) in [`MOI.SOS1{Float64}`](@ref)
 * [`MOI.VectorOfVariables`](@ref) in [`MOI.SOS2{Float64}`](@ref)

List of supported model attributes:

 * [`MOI.HeuristicCallback`](@ref)
 * [`MOI.NLPBlock()`](@ref)
 * [`MOI.ObjectiveSense()`](@ref)
 * [`MOI.UserCutCallback()`](@ref)

## Design considerations

### Optional native-library isolation (experimental fork)

On Linux/glibc, set `SCIPJL_ISOLATE=1` and `SCIPOPTDIR` to a native SCIP
installation, then run `Pkg.build("SCIP")`. Keep `SCIPJL_ISOLATE=1` set before
starting Julia to use isolation. The default outside this project's launcher is
the upstream shared loading mode (`SCIPJL_ISOLATE=0`). Unsupported platforms,
missing builds, or mismatched native libraries fail explicitly.

Both `SCIP.Optimizer(Float64)` and `SCIP.Optimizer(Rational{BigInt})` use the
selected handle. A private glibc namespace keeps SCIP's GMP allocator separate
from Julia's GC-counted allocator. The SCIP binary and optimization settings
are unchanged. The generated API is bound once per process; no native pointers
are saved in precompile caches. JuMP models and other solver connectors need
no changes. Build requires a C compiler (`CC`, default `cc`).

The tiny native companion makes `dlopen` requests local within the private
namespace. This accommodates TBB's allocator loader: glibc does not support its
`RTLD_GLOBAL` requests in a new namespace. Libraries that require process-global
plugin exports are not supported in isolation mode. The companion is never
preloaded into Julia's main namespace and never changes GMP allocation hooks.

Low-level callers must use the generated SCIP API for objects from this
connector. Do not mix pointers with a second `ccall((symbol, SCIP.libscip), ...)`
instance. Native GMP objects, `FILE*` streams and allocated memory must stay
with their owning native library; transfer values through the API instead.
The namespace stays loaded until process exit so finalizers remain valid.

### Wrapping the public API

All of the public API methods are wrapped and available within the `SCIP`
package. This includes the `scip_*.h` and `pub_*.h` headers that are collected
in `scip.h`, as well as all default constraint handlers (`cons_*.h`.)

The wrapped functions do not transform any data structures and work on the *raw*
pointers (for example, `SCIP*` in C, `Ptr{SCIP_}` in Julia). Convenience wrapper
functions based on Julia types are added as needed.

### Memory management

Programming with SCIP requires dealing with variable and constraint objects that
use [reference counting](https://www.scipopt.org/doc/html/OBJ.php) for memory
management.

The `SCIP.Optimizer` wrapper type collects lists of `SCIP_VAR*` and `SCIP_CONS*`
under the hood, and it releases all references when it is garbage collected
itself (via `finalize`).

When adding a variable (`add_variable`) or a constraint (`add_linear_constraint`),
an integer index is returned. This index can be used to retrieve the `SCIP_VAR*`
or `SCIP_CONS*` pointer via `get_var` and `get_cons` respectively.

### Supported nonlinear operators

Supported operators in nonlinear expressions are as follows:

 * `+`
 * `-`
 * `*`
 * `/`
 * `^`
 * `sqrt`
 * `exp`
 * `log`
 * `abs`
 * `cos`
 * `sin`
