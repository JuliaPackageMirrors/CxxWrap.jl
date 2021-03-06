isdefined(Base, :__precompile__) && __precompile__()

module CxxWrap

using Compat

# Convert path if it contains lib prefix on windows
function lib_path(so_path::AbstractString)
  path_copy = so_path
  @static if is_windows()
    basedir, libname = splitdir(so_path)
    libdir_suffix = Sys.WORD_SIZE == 32 ? "32" : ""
    if startswith(libname, "lib") && !isfile(so_path)
      path_copy = joinpath(basedir*libdir_suffix, libname[4:end])
    end
  end
  return path_copy
end

const depsfile = joinpath(dirname(dirname(@__FILE__)), "deps", "deps.jl")
if !isfile(depsfile)
  error("$depsfile not found, CxxWrap did not build properly")
end
include(depsfile)
const cxx_wrap_path = _l_cxx_wrap

# Base type for wrapped C++ types
abstract CppAny
abstract CppDisplay <: Display
abstract CppArray{T,N} <: AbstractArray{T,N}

# C++ std::shared_ptr
type SharedPtr{T} <: CppAny
  cpp_object::Ptr{Void}
end

# C++ std::unique_ptr
type UniquePtr{T} <: CppAny
  cpp_object::Ptr{Void}
end

# Encapsulate information about a function
type CppFunctionInfo
  name::Any
  argument_types::Array{DataType,1}
  return_type::DataType
  function_pointer::Ptr{Void}
  thunk_pointer::Ptr{Void}
end

function __init__()
  @static if is_windows()
    Libdl.dlopen(cxx_wrap_path, Libdl.RTLD_GLOBAL)
  end
  ccall((:initialize, cxx_wrap_path), Void, (Any, Any, Any), CxxWrap, CppAny, CppFunctionInfo)

  Base.linearindexing(::ConstArray) = Base.LinearFast()
  Base.size(arr::ConstArray) = arr.size
end

# Load the modules in the shared library located at the given path
function load_modules(path::AbstractString)
  module_lib = Libdl.dlopen(path, Libdl.RTLD_GLOBAL)
  registry = ccall((:create_registry, cxx_wrap_path), Ptr{Void}, ())
  ccall(Libdl.dlsym(module_lib, "register_julia_modules"), Void, (Ptr{Void},), registry)
  return registry
end

function get_module_names(registry::Ptr{Void})
  ccall((:get_module_names, cxx_wrap_path), Array{AbstractString}, (Ptr{Void},), registry)
end

function get_module_functions(registry::Ptr{Void})
  ccall((:get_module_functions, cxx_wrap_path), Array{CppFunctionInfo}, (Ptr{Void},), registry)
end

function bind_types(registry::Ptr{Void}, m::Module)
  ccall((:bind_module_types, cxx_wrap_path), Void, (Ptr{Void},Any), registry, m)
end

function exported_symbols(registry::Ptr{Void}, modname::AbstractString)
  ccall((:get_exported_symbols, cxx_wrap_path), Array{AbstractString}, (Ptr{Void},AbstractString), registry, modname)
end

# Interpreted as a constructor for Julia  > 0.5
type ConstructorFname
  _type::DataType
end

# Interpreted as an operator call overload
type CallOpOverload
  _type::DataType
end

process_fname(fn::Symbol) = fn
process_fname(fn::ConstructorFname) = :(::$(Type{fn._type}))
function process_fname(fn::CallOpOverload)
  if VERSION < v"0.5-dev"
    return :call
  end
  return :(arg1::$(fn._type))
end

make_func_declaration(fn, argmap) = :($(process_fname(fn))($(argmap...)))
function make_func_declaration(fn::CallOpOverload, argmap)
  if VERSION < v"0.5-dev"
    return :($(process_fname(fn))($(argmap...)))
  end
  return :($(process_fname(fn))($((argmap[2:end])...)))
end

# Build the expression to wrap the given function
function build_function_expression(func::CppFunctionInfo)
  # Arguments and types
  argtypes = func.argument_types
  argsymbols = map((i) -> Symbol(:arg,i[1]), enumerate(argtypes))

  # Function pointer
  fpointer = func.function_pointer
  assert(fpointer != C_NULL)

  # Thunk
  thunk = func.thunk_pointer

  map_arg_type(t::DataType) = ((t <: CppAny) || (t <: CppDisplay) || (t <: Tuple)) || (t <: CppArray) ? Any : t

  # Build the types for the ccall argument list
  c_arg_types = [map_arg_type(t) for t in argtypes]
  return_type = map_arg_type(func.return_type)

  # Build the final call expression
  call_exp = nothing
  if thunk == C_NULL
    call_exp = :(ccall($fpointer, $return_type, ($(c_arg_types...),), $(argsymbols...))) # Direct pointer call
  else
    call_exp = :(ccall($fpointer, $return_type, (Ptr{Void}, $(c_arg_types...)), $thunk, $(argsymbols...))) # use thunk (= std::function)
  end
  assert(call_exp != nothing)

  # Generate overloads for some types
  overload_map = Dict([(Cint,[Int]), (Cuint,[UInt,Int]), (Float64,[Int])])
  nargs = length(argtypes)

  counters = ones(Int, nargs);
  for i in 1:nargs
    if haskey(overload_map, argtypes[i])
        counters[i] += length(overload_map[argtypes[i]])
    end
  end

  function recurse_overloads!(idx::Int, newargs, results)
    if idx > nargs
        push!(results, deepcopy(newargs))
        return
    end
    for i in 1:counters[idx]
        newargs[idx] = i == 1 ? argtypes[idx] : overload_map[argtypes[idx]][i-1]
        recurse_overloads!(idx+1, newargs, results)
    end
  end

  newargs = Array{DataType,1}(nargs);
  overload_sigs = Array{Array{DataType,1},1}();
  recurse_overloads!(1, newargs, overload_sigs);

  function_expressions = quote end
  for overloaded_signature in overload_sigs
    argmap = Expr[]
    for (t, s) in zip(overloaded_signature, argsymbols)
      push!(argmap, :($s::$t))
    end
    func_declaration = make_func_declaration(func.name, argmap)
    push!(function_expressions.args, :($func_declaration = $call_exp))
  end
  return function_expressions
end

# Wrap functions from the cpp module to the passed julia module
function wrap_functions(functions, julia_mod)
  basenames = Set([
    :getindex,
    :setindex!,
    :convert,
    :deepcopy_internal,
    :size,
    :+,
    :*,
    :(==)
  ])
  for func in functions
    if in(func.name, basenames)
      Base.eval(build_function_expression(func))
    else
      julia_mod.eval(build_function_expression(func))
    end
  end
end

# Create modules defined in the given library, wrapping all their functions and types
function wrap_modules(registry::Ptr{Void}, parent_mod=Main)
  module_names = get_module_names(registry)
  jl_modules = Module[]
  for mod_name in module_names
    modsym = Symbol(mod_name)
    jl_mod = parent_mod.eval(:(module $modsym end))
    push!(jl_modules, jl_mod)
    bind_types(registry, jl_mod)
  end

  module_functions = get_module_functions(registry)
  for (jl_mod, mod_functions) in zip(jl_modules, module_functions)
    wrap_functions(mod_functions, jl_mod)
  end

  for (jl_mod, mod_name) in zip(jl_modules, module_names)
    exps = [Symbol(s) for s in exported_symbols(registry, mod_name)]
    jl_mod.eval(:(export $(exps...)))
  end
end

# Wrap modules in the given path
function wrap_modules(so_path::AbstractString, parent_mod=Main)
  registry = CxxWrap.load_modules(lib_path(so_path))
  wrap_modules(registry, parent_mod)
end

# Place the functions and types into the current module
function wrap_module(so_path::AbstractString, parent_mod=Main)
  registry = CxxWrap.load_modules(lib_path(so_path))
  module_names = get_module_names(registry)
  mod_idx = 0
  wanted_name = string(module_name(current_module()))
  for (i,mod_name) in enumerate(module_names)
    if mod_name == wanted_name
      bind_types(registry, current_module())
      mod_idx = i
      break
    end
  end

  if mod_idx == 0
    error("Module $wanted_name not found in C++")
  end

  module_functions = get_module_functions(registry)
  wrap_functions(module_functions[mod_idx], current_module())

  exps = [Symbol(s) for s in exported_symbols(registry, wanted_name)]
  current_module().eval(:(export $(exps...)))
end

export wrap_modules, wrap_module

end # module
