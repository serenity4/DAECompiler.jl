module CthulhuIntegration

using Accessors: setproperties
using Cthulhu: Cthulhu, AbstractCursor, CustomToggle, CthulhuInterpreter, lookup, get_specialization, __descend_with_error_handling, do_typeinf!, get_ci, OptimizedSource
using ..DAECompiler: Settings, ADAnalyzer, structural_analysis, find_matching_ci, StructureCache, ir_to_src

using Compiler: Compiler, AbstractInterpreter, InferenceResult, NativeInterpreter, SOURCE_MODE_GET_SOURCE, get_inference_world, typeinf_ext, Effects
using Core.IR

struct DAEInterpreter <: AbstractInterpreter
    cthulhu::CthulhuInterpreter
    settings::Settings
end
function DAEInterpreter()
    native = NativeInterpreter()
    return DAEInterpreter(CthulhuInterpreter(native), Settings())
end

Base.show(io::IO, interp::DAEInterpreter) = print(io, typeof(interp), "(...)")

Compiler.get_inference_world(interp::DAEInterpreter) = Compiler.get_inference_world(interp.cthulhu)
Compiler.get_inference_cache(interp::DAEInterpreter) = Compiler.get_inference_cache(interp.cthulhu)
Compiler.InferenceParams(interp::DAEInterpreter) = Compiler.InferenceParams(interp.cthulhu)
Compiler.OptimizationParams(interp::DAEInterpreter) = Compiler.OptimizationParams(interp.cthulhu)
Compiler.may_optimize(interp::DAEInterpreter) = Compiler.may_optimize(interp.cthulhu)
Compiler.may_compress(interp::DAEInterpreter) = Compiler.may_compress(interp.cthulhu)
Compiler.may_discard_trees(interp::DAEInterpreter) = Compiler.may_discard_trees(interp.cthulhu)
Compiler.method_table(interp::DAEInterpreter) = Compiler.method_table(interp.cthulhu)
Compiler.cache_owner(interp::DAEInterpreter) = Compiler.cache_owner(interp.cthulhu)

struct DAECursor <: AbstractCursor
    ci::CodeInstance
end

Cthulhu.get_ci(cursor::DAECursor) = cursor.ci

# XXX: Can we wrap `CthulhuInterpreter` to reuse its cache?
# We'll anyways need to either perform type inference on `DAEInterpreter`,
# and cache the results into `CthulhuInterpreter` manually (because `finishinfer!`)
# won't be called on it. Either we define a similar cache ourselves
# (with the relevant lookups), or we 

# For example, type inference after Revise is performed on `CthulhuInterpreter`; but perhaps we should define
# `do_typeinf!` in a way that we can dispatch on the cursor type, DAECursor in our case?

Cthulhu.lookup(interp::DAEInterpreter, cursor::DAECursor, optimize::Bool) = lookup(interp.cthulhu, get_ci(cursor), optimize)

function toggle_setting(interp::DAEInterpreter, setting::Symbol, value)
    return setproperties(interp.settings, NamedTuple{(setting,)}((value,)))
end

function Cthulhu.custom_toggles(interp::DAEInterpreter)
    toggles = [
        CustomToggle(false, 'f', "orce inline all",
            cursor -> toggle_setting(interp, :force_inline_all, true),
            cursor -> toggle_setting(interp, :force_inline_all, false),
        ),
    ]
    return toggles
end

function Cthulhu.run_type_inference(interp::DAEInterpreter, mi::MethodInstance)
    @assert !interp.settings.force_inline_all
    world = get_inference_world(interp)
    analyzer = ADAnalyzer(; world)
    ci = typeinf_ext(analyzer, mi, SOURCE_MODE_GET_SOURCE)
    result = structural_analysis!(ci, world)
    ret = find_matching_ci(ci->ci.owner == StructureCache(), ci.def, world)
    src = ir_to_src(result.ir, interp.settings)
    src.ssavaluetypes = length(src.code)
    src.min_world = @atomic ci.min_world
    src.max_world = @atomic ci.max_world
    src.edges = Core.svec(ci.def)
    source = OptimizedSource(result.ir, src, src.inlineable, Effects())
    interp.cthulhu.opt[ret] = source
    ret::CodeInstance
end

function descend(@nospecialize(args...); @nospecialize(kwargs...))
    settings = Settings()
    interp = DAEInterpreter()
    mi = get_specialization(args...)
    ci = do_typeinf!(interp, mi)
    # interp′, ci = Cthulhu.mkinterp(interp, args...)
    cursor = DAECursor(interp, ci, settings)
    __descend_with_error_handling(interp′, cursor; kwargs...)
end

export descend

end
