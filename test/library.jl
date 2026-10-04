# SPDX-License-Identifier: MIT
using Test, Libdl
import SCIP

@testset "Native library isolation" begin
    function allocators(symbol)
        a = Ref{Ptr{Cvoid}}(); r = Ref{Ptr{Cvoid}}(); f = Ref{Ptr{Cvoid}}()
        ccall(symbol, Cvoid,
              (Ref{Ptr{Cvoid}}, Ref{Ptr{Cvoid}}, Ref{Ptr{Cvoid}}), a, r, f)
        return (a[], r[], f[])
    end
    julia_gmp = Libdl.dlopen(Base.GMP.libgmp)
    try
        julia_get = Libdl.dlsym(julia_gmp, :__gmp_get_memory_functions)
        before = allocators(julia_get)
        native = allocators(SCIP._library_symbol(:__gmp_get_memory_functions))
        @test before[1] == cglobal(:jl_gc_counted_malloc)
        isolated = get(ENV, "SCIPJL_ISOLATE", "0") == "1"
        @test SCIP._library_isolated[] == isolated
        if isolated
            for (pointer, name) in zip(native, (:__gmp_default_allocate, :__gmp_default_reallocate, :__gmp_default_free))
                @test pointer == SCIP._library_symbol(name)
            end
            @test all(native .!= before)
            @test SCIP._library_symbol(:__gmpq_mul) != Libdl.dlsym(julia_gmp, :__gmpq_mul)
            ns = Ref{Clong}()
            @test ccall(:dlinfo, Cint, (Ptr{Cvoid}, Cint, Ref{Clong}), SCIP._library_handle[], 1, ns) == 0
            @test ns[] != 0
        end
        # Keep Julia-owned big integers live while creating/freeing native exact
        # numbers. Force GC to exercise both owners without swapping allocators.
        big_value = big(2)^521 - 1
        for _ in 1:8
            p = Ref{Ptr{SCIP.SCIP_RATIONAL}}(C_NULL)
            @test SCIP.SCIPrationalCreate(p) == SCIP.SCIP_OKAY
            try
                SCIP.SCIPrationalSetString(p[], string(big_value, "/", big_value + 7))
                GC.gc()
                @test SCIP._read_exact(p[]) == big_value // (big_value + 7)
            finally
                SCIP.SCIPrationalFree(p)
            end
        end
        @test allocators(julia_get) == before
        @test allocators(SCIP._library_symbol(:__gmp_get_memory_functions)) == native
        @test big_value + 1 == big(2)^521
        @test SCIP._symbol_path(SCIP._library_symbol(:SCIPmajorVersion)) == realpath(SCIP.libscip)
        @test length(SCIP._library_functions) == length(SCIP._library_names) > 1000
    finally
        Libdl.dlclose(julia_gmp)
    end
end
