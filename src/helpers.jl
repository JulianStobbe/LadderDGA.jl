#TODO: This file needs to be cleaned up. major blocks should be: BLAS helpers, GF helpers, general helpers
#
#TODO: this should be a macro
@inline get_symm_f(f::Array{ComplexF64,1}, i::Int64) = (i < 0) ? conj(f[-i]) : f[i+1]
@inline get_symm_f_1(f::Array{ComplexF64,2}, i::Int64) = (i < 0) ? conj(f[-i,:]) : f[i+1,:]
@inline get_symm_f_2(f::Array{ComplexF64,2}, i::Int64) = (i < 0) ? conj(f[:,-i]) : f[:,i+1]
store_symm_f(f::Array{T, 1}, range::UnitRange{Int64}) where T <: Number = [get_symm_f(f,i) for i in range]
store_symm_f(f::Array{T, 2}, range::UnitRange{Int64}) where T <: Number = [get_symm_f(f,i) for i in range]

# This function exploits, that χ(ν, ω) = χ*(-ν, -ω) and a storage of χ with only positive fermionic frequencies
# TODO: For now a fixed order of axis is assumed


function default_sum_range(mid_index::Int, lim_tuple::Tuple{Int,Int}) where T
    return union((mid_index - lim_tuple[2]):(mid_index - lim_tuple[1]), (mid_index + lim_tuple[1]):(mid_index + lim_tuple[2]))
end


function reduce_range(range::AbstractArray, red_prct::Float64)
    sub = floor(Int, length(range)/2 * red_prct)
    lst = maximum([last(range)-sub, ceil(Int,length(range)/2 + iseven(length(range)))])
    fst = minimum([first(range)+sub, ceil(Int,length(range)/2)])
    return fst:lst
end


split_n(str, n) = [str[(i-n+1):(i)] for i in n:n:length(str)]
split_n(str, n, len) = [str[(i-n+1):(i)] for i in n:n:len]

"""
    print 4 digits of the real part of `x`
"""
printr_s(x::ComplexF64) = round(real(x), digits=4)
printr_s(x::Float64) = round(x, digits=4)


function setup_LDGA(kGridStr::Tuple{String,Int}, mP::ModelParameters, sP::SimulationParameters, env::EnvironmentVars; local_correction=true)

    @info "Setting up calculation for kGrid $(kGridStr[1]) of size $(kGridStr[2])"
    @timeit to "gen kGrid" kGrid    = gen_kGrid(kGridStr[1], kGridStr[2])
    if env.inputDataType == "text"
        convert_from_fortran(sP, env, false)
    elseif env.inputDataType == "parquet"
        convert_from_fortran_pq(sP, env)
    elseif env.inputDataType == "jld2"
        in_file = env.inputDir*"/"*env.inputVars
    end
    @timeit to "load f" χDMFTsp, χDMFTch, Γsp, Γch, gImp_in, Σ_loc = jldopen(in_file, "r") do f 
        #TODO: permute dims creates inconsistency between user input and LadderDGA.jl data!!
        Ns = typeof(sP.χ_helper) === BSE_SC_Helper ? sP.χ_helper.Nν_shell : 0
        χDMFTsp = zeros(_eltype, 2*sP.n_iν, 2*sP.n_iν, 2*sP.n_iω+1)
        χDMFTsp[(Ns+1):(end-Ns),(Ns+1):(end-Ns),:] = permutedims(_eltype === Float64 ? real.(f["χDMFTsp"]) : f["χDMFTsp"], (2,3,1))
        χDMFTch = zeros(_eltype, 2*sP.n_iν, 2*sP.n_iν, 2*sP.n_iω+1)
        χDMFTch[(Ns+1):(end-Ns),(Ns+1):(end-Ns),:] = permutedims(_eltype === Float64 ? real.(f["χDMFTch"]) : f["χDMFTch"], (2,3,1))
        Γsp = zeros(_eltype, 2*sP.n_iν, 2*sP.n_iν, 2*sP.n_iω+1)
        Γsp[(Ns+1):(end-Ns),(Ns+1):(end-Ns),:] = permutedims(_eltype === Float64 ? real.(f["Γsp"]) : f["Γsp"], (2,3,1))
        Γch = zeros(_eltype, 2*sP.n_iν, 2*sP.n_iν, 2*sP.n_iω+1)
        Γch[(Ns+1):(end-Ns),(Ns+1):(end-Ns),:] = permutedims(_eltype === Float64 ? real.(f["Γch"]) : f["Γch"], (2,3,1))
        gImp, Σ_loc = if haskey(f, "g0")
            gImp = f["gImp"]
            g0 = f["g0"]
            Σ_loc = Σ_Dyson(g0, gImp)
            gImp, Σ_loc
        else
            gImp = f["gImp"]
            Σ_loc = f["SigmaLoc"]
            gImp, Σ_loc
        end
        χDMFTsp, χDMFTch, Γsp, Γch, gImp, Σ_loc
    end
    rm = maximum(abs.(sP.fft_range))
    t = cat(conj(reverse(gImp_in[1:rm])),gImp_in[1:rm], dims=1)
    gImp = OffsetArray(reshape(t,1,length(t)),1:1,-length(gImp_in[1:rm]):length(gImp_in[1:rm])-1)
    gLoc_fft = OffsetArray(Array{ComplexF64,2}(undef, kGrid.Nk, length(sP.fft_range)), 1:kGrid.Nk, sP.fft_range)
    gLoc_full = G_from_Σ(Σ_loc, expandKArr(kGrid, kGrid.ϵkGrid)[:], sP.fft_range, mP);
    for (i,el) in enumerate(gLoc_full)
        gLoc_fft[:,sP.fft_range[i]] .= fft(reshape(el, gridshape(kGrid)...))[:]
    end
    gLoc = G_from_Σ(Σ_loc, kGrid.ϵkGrid, sP.fft_range, mP);

    @timeit to "local correction" begin
        #TODO: unify checks
        (sP.ωsum_type == :full && (sP.tc_type_b != :nothing)) && @warn "Full Sums combined with tail correction will probably yield wrong results due to border effects."
        (sP.tc_type_b == :nothing) && @error "Having no tail correction activated usually requires full omega sums in EoM for error compansation. Add full_EoM_omega = true under [Debug] to your config.toml"
        sP.ωsum_type == :individual && @error "Individual ranges not tested yet"
        ((sP.n_iν < 30 || sP.n_iω < 15) && (sP.tc_type_f != :nothing)) && @warn "Improved sums usually require at least 30 positive fermionic frequencies"

        kGridLoc = gen_kGrid(kGridStr[1], 1)
        Fsp   = F_from_χ(χDMFTsp, gImp[1,:], sP, mP.β);
        χ₀Loc = calc_bubble(gImp, kGridLoc, mP, sP, local_tail=true);
        locQ_sp = calc_χγ(:sp, Γsp, χ₀Loc, kGridLoc, mP, sP);
        locQ_ch = calc_χγ(:ch, Γch, χ₀Loc, kGridLoc, mP, sP);
        λ₀Loc = calc_λ0(χ₀Loc, Fsp, locQ_sp, mP, sP)
        Σ_ladderLoc = calc_Σ(locQ_sp, locQ_ch, λ₀Loc, gImp, kGridLoc, mP, sP)
        any(isnan.(Σ_ladderLoc)) && @error "Σ_ladderLoc contains NaN"

        χLocsp_ω = similar(χDMFTsp, size(χDMFTsp,3))
        χLocch_ω = similar(χDMFTch, size(χDMFTch,3))
        for ωi in axes(χDMFTsp,ω_axis)
            if typeof(sP.χ_helper) === BSE_SC_Helper
                @error "SC not fully implemented yet"
                @info "Using asymptotics improvement for large ν, ν' of χ_DMFT with shell size of $(sP.n_iν_shell)"
                improve_χ!(:sp, ωi, view(χDMFTsp,:,:,ωi), view(χ₀Loc,1,:,ωi), mP.U, mP.β, sP.χ_helper);
                improve_χ!(:ch, ωi, view(χDMFTch,:,:,ωi), view(χ₀Loc,1,:,ωi), mP.U, mP.β, sP.χ_helper);
            end
            if typeof(sP.χ_helper) === BSE_Asym_Helper
                χLocsp_ω[ωi] = locQ_sp.χ[ωi]
                χLocch_ω[ωi] = locQ_ch.χ[ωi]
            else
                χLocsp_ω[ωi] = sum_freq_full_f!(view(χDMFTsp,:,:,ωi), mP.β, sP)
                χLocch_ω[ωi] = sum_freq_full_f!(view(χDMFTch,:,:,ωi), mP.β, sP)
            end
        end

        if sP.sumExtrapolationHelper !== nothing
            if sP.sumExtrapolationHelper.ω_smoothing == :full
                ωZero = sP.n_iω
                @warn "smoothing deactivated for now!"
                filter_MA!(χLocsp_ω[1:ωZero],3,χLocsp_ω[1:ωZero])
                filχsp_ω_naiiveter_MA!(χLocsp_ω[ωZero:end],3,χLocsp_ω[ωZero:end])
                filter_MA!(χLocch_ω[1:ωZero],3,χLocch_ω[1:ωZero])
                filter_MA!(χLocch_ω[ωZero:end],3,χLocch_ω[ωZero:end])
                χLocsp_ω_tmp[:] = collect(χLocsp_ω)
                χLocch_ω_tmp[:] = collect(χLocch_ω)
            elseif sP.sumExtrapolationHelper.ω_smoothing == :range
                ωZero = sP.n_iω
                @warn "smoothing deactivated for now!"
                χLocsp_ω_tmp[1:ωZero]   = filter_MA(3,χLocsp_ω[1:ωZero])
                χLocsp_ω_tmp[ωZero:end] = filter_MA(3,χLocsp_ω[ωZero:end])
                χLocch_ω_tmp[1:ωZero]   = filter_MA(3,χLocch_ω[1:ωZero])
                χLocch_ω_tmp[ωZero:end] = filter_MA(3,χLocch_ω[ωZero:end])
            end
        end
    end

    @timeit to "random stuff" begin
        usable_loc_sp = find_usable_interval(real(χLocsp_ω), reduce_range_prct=sP.usable_prct_reduction)
        usable_loc_ch = find_usable_interval(real(χLocch_ω), reduce_range_prct=sP.usable_prct_reduction)
        loc_range = intersect(usable_loc_sp, usable_loc_ch)
        if sP.ωsum_type == :common
            @info "setting usable ranges of sp and ch channel from $usable_loc_sp and $usable_loc_ch to the same range of $loc_range"
            usable_loc_ch = loc_range
            usable_loc_sp = loc_range
        end

        sh_b_sp = get_sum_helper(usable_loc_sp, sP, :b)
        sh_b_ch = get_sum_helper(usable_loc_ch, sP, :b)
        iωn = 1im .* 2 .* (-sP.n_iω:sP.n_iω) .* π ./ mP.β

        @warn "TODO: update local omega sum with correction, update get_sum_helper to return tail sub"
        χLocsp = sP.tc_type_b == :coeffs ? sum(subtract_tail(χLocsp_ω[usable_loc_sp], mP.Ekin_DMFT, iωn[usable_loc_sp]))/mP.β -mP.Ekin_DMFT*mP.β/12 : sum_freq(χLocsp_ω[usable_loc_sp], [1], sh_b_sp, mP.β, 0.0)[1]
        χLocch = sP.tc_type_b == :coeffs ? sum(subtract_tail(χLocch_ω[usable_loc_ch], mP.Ekin_DMFT, iωn[usable_loc_ch]))/mP.β -mP.Ekin_DMFT*mP.β/12 : sum_freq(χLocch_ω[usable_loc_ch], [1], sh_b_ch, mP.β, 0.0)[1]
        #impQ_sp = ImpurityQuantities(Γsp, χDMFTsp, χLocsp_ω, χLocsp, usable_loc_sp, [0,0,mP.Ekin_DMFT])
        #impQ_ch = ImpurityQuantities(Γch, χDMFTch, χLocch_ω, χLocch, usable_loc_ch, [0,0,mP.Ekin_DMFT])

        χupup_DMFT_ω = 0.5 * (χLocsp_ω + χLocch_ω)[loc_range]
        χupup_DMFT_ω_sub = subtract_tail(χupup_DMFT_ω, mP.Ekin_DMFT, iωn[loc_range])

        imp_density_ntc = real(sum(χupup_DMFT_ω))/mP.β
        imp_density = real(sum(χupup_DMFT_ω_sub))/mP.β -mP.Ekin_DMFT*mP.β/12

        @info """Inputs Read. Starting Computation.
          Local susceptibilities with ranges are:
          χLoc_sp($(usable_loc_sp)) = $(printr_s(χLocsp)), χLoc_ch($(usable_loc_ch)) = $(printr_s(χLocch))
          sum χupup check (fit, tail sub, tail sub + fit, expected): $(imp_density_ntc) ?=? $(0.5 .* real(χLocsp + χLocch)) ?≈? $(imp_density) ≟ $(mP.n/2 * ( 1 - mP.n/2))"
          """
    end
    return Σ_ladderLoc, Σ_loc, imp_density, kGrid, gLoc_full, gLoc_fft, Γsp, Γch, χDMFTsp, χDMFTch, locQ_sp, locQ_ch, χ₀Loc, gImp
end
#TODO: cleanup clutter in return

# ================== Index Functions ==================

function flatten_2D(arr)
    res = zeros(eltype(arr[1]),length(arr), length(arr[1]))
    for i in 1:length(arr)
        res[i,:] = arr[i][:]
    end
    return res
end

"""
    OneToIndex_to_Freq(ωi::Int, νi::Int, sP::SimulationParameters [, Nν_shell])

Converts `(1:N,1:N)` index tuple for bosonic (`ωi`) and fermionic (`νi`) frequency to
Matsubara frequency number. If the array has a `ν` shell (for example for tail
improvements) this will also be taken into account by providing `Nν_shell`.
"""
@inline function OneToIndex_to_Freq(ωi::Int, νi::Int, sP::SimulationParameters, Nν_shell)
    ωn = ωi-sP.n_iω-1
    νn = (νi-sP.n_iν-Nν_shell-1) - sP.shift*trunc(Int,ωn/2)
    return ωn, νn
end

@inline function OneToIndex_to_Freq(ωi::Int, νi::Int, sP::SimulationParameters)
    ωn = ωi-sP.n_iω-1
    νn = (νi-sP.n_iν-1) - sP.shift*trunc(Int,ωn/2)
    return ωn, νn
end

@inline ν0Index_of_ωIndex(ωi::Int, sP)::Int = sP.n_iν + sP.shift*(trunc(Int, (ωi - sP.n_iω - 1)/2)) + 1

"""
    to_m_index(arr::AbstractArray{T,2/3}, sP::SimulationParameters)

Converts array with simpel `1:N` index to larger array, where the index matches the Matsubara
Frequency number. This function is not optimized!
"""
function to_m_index(arr::AbstractArray{T,3}, sP::SimulationParameters) where T
    ωrange = -sP.n_iω:sP.n_iω
    νrange = -2*sP.n_iν:2*sP.n_iν
    length(ωrange) != size(arr,3) && @error "Assumption -n_iω:n_iω for ω grid not fulfilled."
    ωl = length(ωrange)
    νl = length(νrange)
    res = OffsetArray(zeros(ComplexF64, size(arr,1), νl, ωl), 1:size(arr,1) ,νrange, ωrange)
    for qi in 1:size(arr,1)
        to_m_index!(view(res,qi,:,:),view(arr,qi,:,:), sP)
    end
    return res
end

function to_m_index(arr::AbstractArray{T,2}, sP::SimulationParameters) where T
    ωrange = -sP.n_iω:sP.n_iω
    νrange = -2*sP.n_iν:2*sP.n_iν
    length(ωrange) != size(arr,2) && @error "Assumption -n_iω:n_iω for ω grid not fulfilled."
    ωl = length(ωrange)
    νl = length(νrange)
    res = OffsetArray(zeros(ComplexF64, νl,ωl), νrange, ωrange)
    to_m_index!(res, arr, sP)
    return res
end

function to_m_index!(res::AbstractArray{T,2}, arr::AbstractArray{T,2}, sP::SimulationParameters) where T
    for ωi in 1:size(arr,2)
        for νi in 1:size(arr,1)
            ωn,νn = OneToIndex_to_Freq(ωi, νi, sP)
            @inbounds res[νn, ωn] = arr[νi,ωi]
        end
    end
    return res
end

function ωindex_range(sP::SimulationParameters)
    r = 1:(2*sP.n_iω+1)
    ωindices = if sP.fullChi
        r 
    elseif fixed_ω
        mid_index = Int(ceil(length(r)/2))
        default_sum_range(mid_index, sP.ωsum_type)
    else
        indh = ceil(Int64, length(r)/2)
        [(i == 0) ? indh : ((i % 2 == 0) ? indh+floor(Int64,i/2) : indh-floor(Int64,i/2)) for i in r]
    end
    return ωindices
end

"""
    flatten_gLoc(kG::ReducedKGrid, arr::AbstractArray{AbstractArray})

transform Array{Array,1}(Nf) of Arrays to Array of dim `(Nk,Nk,...,Nf)`. Number of dimensions
depends on grid shape.
"""
function flatten_gLoc(arr::AbstractArray)
    ndim = length(size(arr[1]))+1
    arr_new = Array{eltype(arr[1]),ndim}(undef,size(arr[1])...,length(arr));
    for (i,el) in enumerate(arr)
        selectdim(arr_new, ndim, i) .= el
    end
    return arr_new
end


# ================== Noise Filter ==================

function filter_MA(m::Int, X::AbstractArray{T,1}) where T <: Number
    res = deepcopy(X)
    offset = trunc(Int,m/2)
    res[1+offset] = sum(@view X[1:m])/m
    for (ii,i) in enumerate((2+offset):(length(X)-offset))
        res[i] = res[i-1] + (X[m+ii] - X[ii])/m
    end
    return res
end

function filter_MA!(res::AbstractArray{T,1}, m::Int, X::AbstractArray{T,1}) where T <: Number
    offset = trunc(Int,m/2)
    res[1+offset] = sum(@view X[1:m])/m
    for (ii,i) in enumerate((2+offset):(length(X)-offset))
        res[i] = res[i-1] + (X[m+ii] - X[ii])/m
    end
    return res
end

function filter_KZ(m::Int, k::Int, X::AbstractArray{T,1}) where T <: Number
    res = filter_MA(m, X)
    for ki in 2:k
        res = filter_MA!(res, m, res)
    end
    return res
end

q0_index(kG::ReducedKGrid) = findfirst(x -> all(x .== (0,0,0)), kG.kGrid)
#TODO: most quantities should know their indices! Implement this in DataTypes
ω0_index(sP::SimulationParameters) = sP.n_iω+1

function log_q0_χ_check(kG::ReducedKGrid, sP::SimulationParameters, χ::AbstractArray{_eltype,2}, type::Symbol)
    q0_ind = q0_index(kG)
    if q0_ind != nothing
        ω_ind = setdiff(1:size(χ,2), sP.n_iω+1)#TODO: adapt for arbitrary ω indices
        @info "$type channel: |∑χ(q=0,ω≠0)| = $(round(abs(sum(view(χ,q0_ind,ω_ind))),digits=12)) ≟ 0"
    end
end

