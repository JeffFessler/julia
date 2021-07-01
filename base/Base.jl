# This file is a part of Julia. License is MIT: https://julialang.org/license

baremodule Base

using Core.Intrinsics, Core.IR

# to start, we're going to use a very simple definition of `include`
# that doesn't require any function (except what we can get from the `Core` top-module)
const _included_files = Array{Tuple{Module,String},1}()
function include(mod::Module, path::String)
    ccall(:jl_array_grow_end, Cvoid, (Any, UInt), _included_files, UInt(1))
    Core.arrayset(true, _included_files, (mod, ccall(:jl_prepend_cwd, Any, (Any,), path)), arraylen(_included_files))
    Core.println(path)
    ccall(:jl_uv_flush, Nothing, (Ptr{Nothing},), Core.io_pointer(Core.stdout))
    Core.include(mod, path)
end
include(path::String) = include(Base, path)

# from now on, this is now a top-module for resolving syntax
const is_primary_base_module = ccall(:jl_module_parent, Ref{Module}, (Any,), Base) === Core.Main
ccall(:jl_set_istopmod, Cvoid, (Any, Bool), Base, is_primary_base_module)

# The real @inline macro is not available until after array.jl, so this
# internal macro splices the meta Expr directly into the function body.
macro _inline_meta()
    Expr(:meta, :inline)
end
macro _noinline_meta()
    Expr(:meta, :noinline)
end

# Try to help prevent users from shooting them-selves in the foot
# with ambiguities by defining a few common and critical operations
# (and these don't need the extra convert code)
getproperty(x::Module, f::Symbol) = (@_inline_meta; getfield(x, f))
setproperty!(x::Module, f::Symbol, v) = setfield!(x, f, v) # to get a decent error
getproperty(x::Type, f::Symbol) = (@_inline_meta; getfield(x, f))
setproperty!(x::Type, f::Symbol, v) = error("setfield! fields of Types should not be changed")
getproperty(x::Tuple, f::Int) = (@_inline_meta; getfield(x, f))
setproperty!(x::Tuple, f::Int, v) = setfield!(x, f, v) # to get a decent error

getproperty(x, f::Symbol) = (@_inline_meta; getfield(x, f))
setproperty!(x, f::Symbol, v) = setfield!(x, f, convert(fieldtype(typeof(x), f), v))

dotgetproperty(x, f) = getproperty(x, f)

getproperty(x::Module, f::Symbol, order::Symbol) = (@_inline_meta; getfield(x, f, order))
setproperty!(x::Module, f::Symbol, v, order::Symbol) = setfield!(x, f, v, order) # to get a decent error
getproperty(x::Type, f::Symbol, order::Symbol) = (@_inline_meta; getfield(x, f, order))
setproperty!(x::Type, f::Symbol, v, order::Symbol) = error("setfield! fields of Types should not be changed")
getproperty(x::Tuple, f::Int, order::Symbol) = (@_inline_meta; getfield(x, f, order))
setproperty!(x::Tuple, f::Int, v, order::Symbol) = setfield!(x, f, v, order) # to get a decent error

getproperty(x, f::Symbol, order::Symbol) = (@_inline_meta; getfield(x, f, order))
setproperty!(x, f::Symbol, v, order::Symbol) = (@_inline_meta; setfield!(x, f, convert(fieldtype(typeof(x), f), v), order))

swapproperty!(x, f::Symbol, v, order::Symbol=:notatomic) =
    (@_inline_meta; Core.swapfield!(x, f, convert(fieldtype(typeof(x), f), v), order))
modifyproperty!(x, f::Symbol, op, v, order::Symbol=:notatomic) =
    (@_inline_meta; Core.modifyfield!(x, f, op, v, order))
replaceproperty!(x, f::Symbol, expected, desired, success_order::Symbol=:notatomic, fail_order::Symbol=success_order) =
    (@_inline_meta; Core.replacefield!(x, f, expected, convert(fieldtype(typeof(x), f), desired), success_order, fail_order))


# for closures
function _typeof_captured_variable(Core.@nospecialize x)
    if x isa DataType
        if x.layout === C_NULL
            return DataType
        end
    end
    return Core.Typeof(x)
end

include("coreio.jl")

eval(x) = Core.eval(Base, x)
eval(m::Module, x) = Core.eval(m, x)

# init core docsystem
import Core: @doc, @__doc__, WrappedException, @int128_str, @uint128_str, @big_str, @cmd
if isdefined(Core, :Compiler)
    import Core.Compiler.CoreDocs
    Core.atdoc!(CoreDocs.docm)
end

include("exports.jl")

if false
    # simple print definitions for debugging. enable these if something
    # goes wrong during bootstrap before printing code is available.
    # otherwise, they just just eventually get (noisily) overwritten later
    global show, print, println
    show(io::IO, x) = Core.show(io, x)
    print(io::IO, a...) = Core.print(io, a...)
    println(io::IO, x...) = Core.println(io, x...)
end

"""
    time_ns()

Get the time in nanoseconds. The time corresponding to 0 is undefined, and wraps every 5.8 years.
"""
time_ns() = ccall(:jl_hrtime, UInt64, ())

start_base_include = time_ns()

## Load essential files and libraries
include("essentials.jl")
include("ctypes.jl")
include("gcutils.jl")
include("generator.jl")
include("reflection.jl")
include("options.jl")

# core operations & types
include("promotion.jl")
include("tuple.jl")
include("expr.jl")
include("pair.jl")
include("traits.jl")
include("range.jl")
include("error.jl")

# core numeric operations & types
==(x, y) = x === y
include("bool.jl")
include("number.jl")
include("int.jl")
include("operators.jl")
include("pointer.jl")
include("refvalue.jl")
include("refpointer.jl")
include("checked.jl")
using .Checked

# array structures
include("indices.jl")
include("array.jl")
include("abstractarray.jl")
include("subarray.jl")
include("views.jl")
include("baseext.jl")

include("ntuple.jl")

include("abstractdict.jl")
include("iddict.jl")
include("idset.jl")

include("iterators.jl")
using .Iterators: zip, enumerate, only
using .Iterators: Flatten, Filter, product  # for generators

include("namedtuple.jl")

# For OS specific stuff
# We need to strcat things here, before strings are really defined
function strcat(x::String, y::String)
    out = ccall(:jl_alloc_string, Ref{String}, (Csize_t,), Core.sizeof(x) + Core.sizeof(y))
    GC.@preserve x y out begin
        out_ptr = unsafe_convert(Ptr{UInt8}, out)
        unsafe_copyto!(out_ptr, unsafe_convert(Ptr{UInt8}, x), Core.sizeof(x))
        unsafe_copyto!(out_ptr + Core.sizeof(x), unsafe_convert(Ptr{UInt8}, y), Core.sizeof(y))
    end
    return out
end
include(strcat((length(Core.ARGS)>=2 ? Core.ARGS[2] : ""), "build_h.jl"))     # include($BUILDROOT/base/build_h.jl)
include(strcat((length(Core.ARGS)>=2 ? Core.ARGS[2] : ""), "version_git.jl")) # include($BUILDROOT/base/version_git.jl)

# numeric operations
include("hashing.jl")
include("rounding.jl")
using .Rounding
include("div.jl")
include("float.jl")
include("twiceprecision.jl")
include("complex.jl")
include("rational.jl")
include("multinverses.jl")
using .MultiplicativeInverses
include("abstractarraymath.jl")
include("arraymath.jl")

# SIMD loops
@pure sizeof(s::String) = Core.sizeof(s)  # needed by gensym as called from simdloop
include("simdloop.jl")
using .SimdLoop

# map-reduce operators
include("reduce.jl")

## core structures
include("reshapedarray.jl")
include("reinterpretarray.jl")
include("bitarray.jl")
include("bitset.jl")

if !isdefined(Core, :Compiler)
    include("docs/core.jl")
    Core.atdoc!(CoreDocs.docm)
end

include("multimedia.jl")
using .Multimedia

# Some type
include("some.jl")

include("dict.jl")
include("abstractset.jl")
include("set.jl")

include("char.jl")
include("strings/basic.jl")
include("strings/string.jl")
include("strings/substring.jl")

# Initialize DL_LOAD_PATH as early as possible.  We are defining things here in
# a slightly more verbose fashion than usual, because we're running so early.
const DL_LOAD_PATH = String[]
let os = ccall(:jl_get_UNAME, Any, ())
    if os === :Darwin || os === :Apple
        if Base.DARWIN_FRAMEWORK
            push!(DL_LOAD_PATH, "@loader_path/Frameworks")
        else
            push!(DL_LOAD_PATH, "@loader_path/julia")
        end
        push!(DL_LOAD_PATH, "@loader_path")
    end
end

include("osutils.jl")
include("c.jl")

# Core I/O
include("io.jl")
include("iobuffer.jl")

# strings & printing
include("intfuncs.jl")
include("strings/strings.jl")
include("regex.jl")
include("parse.jl")
include("shell.jl")
include("show.jl")
include("arrayshow.jl")
include("methodshow.jl")

# multidimensional arrays
include("cartesian.jl")
using .Cartesian
include("multidimensional.jl")

include("broadcast.jl")
using .Broadcast
using .Broadcast: broadcasted, broadcasted_kwsyntax, materialize, materialize!,
                  broadcast_preserving_zero_d, andand, oror

# missing values
include("missing.jl")

# version
include("version.jl")

# system & environment
include("sysinfo.jl")
include("libc.jl")
using .Libc: getpid, gethostname, time

# Logging
include("logging.jl")
using .CoreLogging

# Concurrency
include("linked_list.jl")
include("condition.jl")
include("threads.jl")
include("lock.jl")
include("channels.jl")
include("task.jl")
include("threads_overloads.jl")
include("weakkeydict.jl")

include("env.jl")

# BinaryPlatforms, used by Artifacts
include("binaryplatforms.jl")

# functions defined in Random
function rand end
function randn end

# I/O
include("libuv.jl")
include("asyncevent.jl")
include("iostream.jl")
include("stream.jl")
include("filesystem.jl")
using .Filesystem
include("cmd.jl")
include("process.jl")
include("ttyhascolor.jl")
include("secretbuffer.jl")

# core math functions
include("floatfuncs.jl")
include("math.jl")
using .Math
const (√)=sqrt
const (∛)=cbrt

# now switch to a simple, race-y TLS, relative include for the rest of Base
delete_method(which(include, (Module, String)))
let SOURCE_PATH = ""
    global function include(mod::Module, path::String)
        prev = SOURCE_PATH::String
        path = normpath(joinpath(dirname(prev), path))
        Core.println(path)
        ccall(:jl_uv_flush, Nothing, (Ptr{Nothing},), Core.io_pointer(Core.stdout))
        push!(_included_files, (mod, abspath(path)))
        SOURCE_PATH = path
        result = Core.include(mod, path)
        SOURCE_PATH = prev
        return result
    end
end

# reduction along dims
include("reducedim.jl")  # macros in this file relies on string.jl
include("accumulate.jl")

include("permuteddimsarray.jl")
using .PermutedDimsArrays

# basic data structures
include("ordering.jl")
using .Order

# Combinatorics
include("sort.jl")
using .Sort

# Fast math
include("fastmath.jl")
using .FastMath

function deepcopy_internal end

# enums
include("Enums.jl")
using .Enums

# BigInts
include("gmp.jl")
using .GMP

# float printing: requires BigInt
include("ryu/Ryu.jl")
using .Ryu

# BigFloats
include("mpfr.jl")
using .MPFR

include("combinatorics.jl")

# irrational mathematical constants
include("irrationals.jl")
include("mathconstants.jl")
using .MathConstants: ℯ, π, pi

# metaprogramming
include("meta.jl")

# Stack frames and traces
include("stacktraces.jl")
using .StackTraces

# experimental API's
include("experimental.jl")

# utilities
include("deepcopy.jl")
include("download.jl")
include("summarysize.jl")
include("errorshow.jl")

include("initdefs.jl")

# worker threads
include("threadcall.jl")

# code loading
include("uuid.jl")
include("pkgid.jl")
include("toml_parser.jl")
include("loading.jl")

# misc useful functions & macros
include("timing.jl")
include("util.jl")

include("asyncmap.jl")

# deprecated functions
include("deprecated.jl")

# Some basic documentation
include("docs/basedocs.jl")

include("client.jl")

# Documentation -- should always be included last in sysimg.
include("docs/Docs.jl")
using .Docs
if isdefined(Core, :Compiler) && is_primary_base_module
    Docs.loaddocs(Core.Compiler.CoreDocs.DOCS)
end

# finally, now make `include` point to the full version
for m in methods(include)
    delete_method(m)
end
# These functions are duplicated in client.jl/include(::String) for
# nicer stacktraces. Modifications here have to be backported there
include(mod::Module, _path::AbstractString) = _include(identity, mod, _path)
include(mapexpr::Function, mod::Module, _path::AbstractString) = _include(mapexpr, mod, _path)

end_base_include = time_ns()

const _sysimage_modules = PkgId[]
in_sysimage(pkgid::PkgId) = pkgid in _sysimage_modules

# Precompiles for Revise
# TODO: move these to contrib/generate_precompile.jl
# The problem is they don't work there
for match = _methods(+, (Int, Int), -1, get_world_counter())
    m = match.method
    delete!(push!(Set{Method}(), m), m)
    copy(Core.Compiler.retrieve_code_info(Core.Compiler.specialize_method(match)))

    empty!(Set())
    push!(push!(Set{Union{GlobalRef,Symbol}}(), :two), GlobalRef(Base, :two))
    (setindex!(Dict{String,Base.PkgId}(), Base.PkgId(Base), "file.jl"))["file.jl"]
    (setindex!(Dict{Symbol,Vector{Int}}(), [1], :two))[:two]
    (setindex!(Dict{Base.PkgId,String}(), "file.jl", Base.PkgId(Base)))[Base.PkgId(Base)]
    (setindex!(Dict{Union{GlobalRef,Symbol}, Vector{Int}}(), [1], :two))[:two]
    (setindex!(IdDict{Type, Union{Missing, Vector{Tuple{LineNumberNode, Expr}}}}(), missing, Int))[Int]
    Dict{Symbol, Union{Nothing, Bool, Symbol}}(:one => false)[:one]
    Dict(Base => [:(1+1)])[Base]
    Dict(:one => [1])[:one]
    Dict("abc" => Set())["abc"]
    pushfirst!([], sum)
    get(Base.pkgorigins, Base.PkgId(Base), nothing)
    sort!([1,2,3])
    unique!([1,2,3])
    cumsum([1,2,3])
    append!(Int[], BitSet())
    isempty(BitSet())
    delete!(BitSet([1,2]), 3)
    deleteat!(Int32[1,2,3], [1,3])
    deleteat!(Any[1,2,3], [1,3])
    Core.svec(1, 2) == Core.svec(3, 4)
    any(t->t[1].line > 1, [(LineNumberNode(2,:none), :(1+1))])

    # Code loading uses this
    sortperm(mtime.(readdir(".")), rev=true)

    break   # only actually need to do this once
end

if is_primary_base_module
function __init__()
    # try to ensuremake sure OpenBLAS does not set CPU affinity (#1070, #9639)
    if !haskey(ENV, "OPENBLAS_MAIN_FREE") && !haskey(ENV, "GOTOBLAS_MAIN_FREE")
        ENV["OPENBLAS_MAIN_FREE"] = "1"
    end
    # And try to prevent openblas from starting too many threads, unless/until specifically requested
    if !haskey(ENV, "OPENBLAS_NUM_THREADS") && !haskey(ENV, "OMP_NUM_THREADS")
        cpu_threads = Sys.CPU_THREADS::Int
        if cpu_threads > 8 # always at most 8
            ENV["OPENBLAS_NUM_THREADS"] = "8"
        elseif haskey(ENV, "JULIA_CPU_THREADS") # or exactly as specified
            ENV["OPENBLAS_NUM_THREADS"] = cpu_threads
        end # otherwise, trust that openblas will pick CPU_THREADS anyways, without any intervention
    end
    # for the few uses of Libc.rand in Base:
    Libc.srand()
    # Base library init
    reinit_stdio()
    Multimedia.reinit_displays() # since Multimedia.displays uses stdout as fallback
    # initialize loading
    init_depot_path()
    init_load_path()
    init_active_project()
    append!(empty!(_sysimage_modules), keys(loaded_modules))
    if haskey(ENV, "JULIA_MAX_NUM_PRECOMPILE_FILES")
        MAX_NUM_PRECOMPILE_FILES[] = parse(Int, ENV["JULIA_MAX_NUM_PRECOMPILE_FILES"])
    end
    nothing
end

end

end # baremodule Base
