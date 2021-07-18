# ===================== Dependencies ======================
using ArgParse
using Logging
using Distributed
using SharedArrays
using OffsetArrays
using JLD2, FileIO
using DelimitedFiles
using LinearAlgebra, GenericLinearAlgebra
using Combinatorics
using TOML          # used for input
using Printf
using ForwardDiff
using Query
using IntervalArithmetic, IntervalRootFinding
using Roots
using PaddedViews   # used to pad fft arrays
using FFTW          # used for convolutions
using NLsolve

using SeriesAcceleration
using Dispersions


# ======================= Includes ========================
include("$(@__DIR__)/Config.jl")
include("$(@__DIR__)/DataTypes.jl")
include("$(@__DIR__)/helpers.jl")
include("$(@__DIR__)/IO.jl")
include("$(@__DIR__)/GFTools.jl")
include("$(@__DIR__)/GFFit.jl")
include("$(@__DIR__)/ladderDGATools.jl")
include("$(@__DIR__)/lambdaCorrection.jl")
include("$(@__DIR__)/thermodynamics.jl")


# if (myid()==1) && (nprocs()==1)
#   println("activating procs")
#   addprocs(3)
#end
#
# ==================== Argument Parser ====================
s = ArgParseSettings()
@add_arg_table s begin
    "--config", "-c"
        help = "configuration file, default `config.toml`"
        arg_type = String
        default = "config.toml"
end

args = parse_args([], s)
io = stdout
metafmt(level::Logging.LogLevel, _module, group, id, file, line) = Logging.default_metafmt(level, nothing, group,id, nothing, nothing)
logger = ConsoleLogger(io, Logging.Info, meta_formatter=metafmt, show_limited=true, right_justify=0)
global_logger(logger)

