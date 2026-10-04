# SPDX-License-Identifier: MIT
# Route generated C bindings through one library handle. Pointer tables are
# populated at runtime, never serialized into a precompile cache.
const _library_handle = Ref{Ptr{Cvoid}}(C_NULL)
const _library_isolated = Ref(false)
const _library_names = Symbol[]
const _library_functions = Ptr{Cvoid}[]

function _bind_library_calls(ex)
    ex isa Expr || return ex
    if ex.head == :call && ex.args[1] == :ccall
        target = ex.args[2]
        if target isa Expr && target.head == :tuple &&
           length(target.args) == 2 && target.args[2] == :libscip
            name = target.args[1]
            name isa QuoteNode && name.value isa Symbol || error("Unexpected SCIP C binding")
            push!(_library_names, name.value)
            ex.args[2] = Expr(:call, GlobalRef(@__MODULE__, :_library_function), length(_library_names))
        end
    end
    return Expr(ex.head, map(_bind_library_calls, ex.args)...)
end

@inline function _library_function(i::Int)
    pointer = _library_functions[i]
    pointer == C_NULL && error("SCIP library does not export $(_library_names[i])")
    return pointer
end

function _load_library()
    mode = get(ENV, "SCIPJL_ISOLATE", "0")
    mode in ("0", "1") || error("SCIPJL_ISOLATE must be 0 or 1")
    if mode == "1"
        Sys.islinux() || error("SCIPJL_ISOLATE requires Linux with glibc")
        loader = Libdl.dlopen("") do process
            Libdl.dlsym(process, :dlmopen; throw_error=false)
        end
        loader === nothing && error("SCIPJL_ISOLATE requires glibc dlmopen")
        path = joinpath(@__DIR__, "..", "deps", "libscipjl_namespace.so")
        isfile(path) || error("Build SCIP.jl with SCIPJL_ISOLATE=1 and SCIPOPTDIR before enabling isolation")
        # glibc constants: LM_ID_NEWLM=-1, RTLD_NOW=2, RTLD_LOCAL=0.
        # Julia Libdl flag values are not the native glibc constants.
        handle = ccall(loader, Ptr{Cvoid}, (Clong, Cstring, Cint), -1, path, 2)
        if handle == C_NULL
            detail = ccall(:dlerror, Cstring, ())
            error("Cannot isolate SCIP: ", detail == C_NULL ? "unknown loader error" : unsafe_string(detail))
        end
        _library_isolated[] = true
        _symbol_path(Libdl.dlsym(handle, :SCIPmajorVersion)) == realpath(libscip) ||
            error("Isolated loader links a different SCIP; rebuild SCIP.jl")
        alloc = Ref{Ptr{Cvoid}}(); realloc = Ref{Ptr{Cvoid}}(); release = Ref{Ptr{Cvoid}}()
        get_allocators = Libdl.dlsym(handle, :__gmp_get_memory_functions)
        ccall(get_allocators, Cvoid,
              (Ref{Ptr{Cvoid}}, Ref{Ptr{Cvoid}}, Ref{Ptr{Cvoid}}), alloc, realloc, release)
        alloc[] == Libdl.dlsym(handle, :__gmp_default_allocate) ||
            error("Isolated SCIP is not using GMP's native allocator")
    else
        handle = Libdl.dlopen(libscip)
    end
    # Keep the handle for the process lifetime: SCIP finalizers can run at exit.
    _library_handle[] = handle
    resize!(_library_functions, length(_library_names))
    for (i, name) in enumerate(_library_names)
        # Bindings cover multiple SCIP versions; unavailable functions fail only
        # when called, just as ordinary ccall bindings do.
        _library_functions[i] = something(Libdl.dlsym(handle, name; throw_error=false), C_NULL)
    end
    return nothing
end

function _library_symbol(name::Symbol)
    _library_handle[] != C_NULL || error("SCIP library has not been initialized")
    return Libdl.dlsym(_library_handle[], name)
end

function _symbol_path(pointer::Ptr{Cvoid})
    info = Ref{NTuple{4,Ptr{Cvoid}}}()
    ccall(:dladdr, Cint, (Ptr{Cvoid}, Ref{NTuple{4,Ptr{Cvoid}}}), pointer, info) != 0 ||
        error("Cannot identify native library")
    return realpath(unsafe_string(Ptr{UInt8}(info[][1])))
end
