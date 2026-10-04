# Copyright (c) 2018 Felipe Serrano, Miles Lubin, Robert Schwarz, and contributors
#
# Use of this source code is governed by an MIT-style license that can be found
# in the LICENSE.md file or at https://opensource.org/licenses/MIT.

using Libdl

if !haskey(ENV, "SCIPOPTDIR")
    # Skip build in favor of SCIP_jll
    exit()
end

depsfile = joinpath(dirname(@__FILE__), "deps.jl")
if isfile(depsfile)
    rm(depsfile)
end

function write_depsfile(path)
    if get(ENV, "SCIPJL_ISOLATE", "0") == "1"
        Sys.islinux() || error("SCIPJL_ISOLATE requires Linux with glibc")
        path = realpath(path)
        source = joinpath(@__DIR__, "namespace.c")
        output = joinpath(@__DIR__, "libscipjl_namespace.so")
        compiler = get(ENV, "CC", "cc")
        # One small C loader; SCIP itself is not rebuilt or modified.
        run(`$compiler -O2 -shared -fPIC $source -Wl,--no-as-needed $path -Wl,-rpath,$(dirname(path)) -ldl -o $output`)
    end
    open(depsfile, "w") do f
        print(f, "const libscip = ")
        show(f, path)
        println(f)
    end
end

libname = if Sys.islinux()
    "libscip.so"
elseif Sys.isapple()
    "libscip.dylib"
elseif Sys.iswindows()
    "libscip.dll"
else
    error("SCIP is currently not supported on \"$(Sys.KERNEL)\"")
end

paths_to_try = []

# prefer environment variable
if haskey(ENV, "SCIPOPTDIR")
    push!(paths_to_try, joinpath(ENV["SCIPOPTDIR"], "bin", libname))
    push!(paths_to_try, joinpath(ENV["SCIPOPTDIR"], "lib", libname))
end

# but also try library path
push!(paths_to_try, libname)

found = false
tried = String[]
for l in paths_to_try
    try
        Libdl.dlopen(l) do handle
            nothing
        end
    catch e
        push!(tried, "$(l): $(sprint(showerror, e))")
        continue
    end
    write_depsfile(l)
    global found = true
    break
end

if !found && !haskey(ENV, "SCIP_JL_SKIP_LIB_CHECK")
    error("""
Unable to locate SCIP installation. Tried:

$(join(tried, "\n\n"))

Note that this must be downloaded separately from https://scipopt.org.
Please set the environment variable SCIPOPTDIR to SCIP's installation path.
""")
end
