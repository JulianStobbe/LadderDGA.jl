dχ_λ(χ, λ::Float64) = map(χi -> - ((1.0 / χi) + λ)^(-2), χ)
χ_λ2(χ, λ) = map(χi -> 1.0 / ((1.0 / χi) + λ), χ)

function χ_λ(χ::AbstractArray{T}, λ::Float64) where T <: Union{ComplexF64, Float64}
    res = similar(χ)
    χ_λ!(res, χ, λ)
    return res
end

function χ_λ!(χ_λ::AbstractArray{T}, χ::AbstractArray{T}, λ::Float64) where T <: Union{ComplexF64, Float64}
    for i in eachindex(χ_λ)
        χ_λ[i] = 1.0 / ((1.0 / χ[i]) + λ)
    end
end

function χ_λ!(χ_λ::AbstractArray{T,2}, χ::AbstractArray{T,2}, λ::Float64, ωindices::AbstractArray{Int,1}) where T <: Number
    for i in ωindices
        χ_λ[:,i] = 1.0 ./ ((1.0 ./ χ[:,i]) .+ λ)
    end
end


dΣch_λ_amp(G_plus_νq, γch, dχch_λ, qNorm) = -sum(G_plus_νq .* γch .* dχch_λ)*qNorm
dΣsp_λ_amp(G_plus_νq, γsp, dχsp_λ, qNorm) = -1.5*sum(G_plus_νq .* γsp .* dχsp_λ)*qNorm

function calc_λsp_rhs_usable(impQ_sp::ImpurityQuantities, impQ_ch::ImpurityQuantities, nlQ_sp::NonLocalQuantities, nlQ_ch::NonLocalQuantities, kG::ReducedKGrid, mP::ModelParameters, sP::SimulationParameters)
    usable_ω = intersect(nlQ_sp.usable_ω, nlQ_ch.usable_ω)
    χch_ω = kintegrate(kG, nlQ_ch.χ[:,usable_ω], 1)[1,:]
    @warn "currently using min(usable_sp, usable_ch) = min($(nlQ_sp.usable_ω),$(nlQ_ch.usable_ω)) = $(usable_ω) for all calculations. relax this?"

    iωn = 1im .* 2 .* (-sP.n_iω:sP.n_iω)[usable_ω] .* π ./ mP.β
    χch_ω_sub = subtract_tail(χch_ω, impQ_ch.tailCoeffs[3], iωn)

    #TODO: this should use sum_freq instead of naiive sum()
    χch_sum = real(sum(χch_ω_sub))/mP.β - impQ_ch.tailCoeffs[3]*mP.β/12

    rhs = ((sP.tc_type_b != :nothing && sP.λ_rhs == :native) || sP.λ_rhs == :fixed) ? mP.n * (1 - mP.n/2) - χch_sum : real(impQ_ch.χ_loc + impQ_sp.χ_loc - χch_sum)

    @info """Found usable intervals for non-local susceptibility of length 
          sp: $(nlQ_sp.usable_ω), length: $(length(nlQ_sp.usable_ω))
          ch: $(nlQ_ch.usable_ω), length: $(length(nlQ_ch.usable_ω))
          usable: $(usable_ω), length: $(length(usable_ω))
          χch sum = $(χch_sum), rhs = $(rhs)"""
    return rhs, usable_ω
end

function λsp(χr::Array{Float64,2}, iωn::Array{ComplexF64,1}, EKin::Float64,
                            rhs::Float64, kG::ReducedKGrid, mP::ModelParameters)
    #TODO: this should use sum_freq instead of naiive sum()
    f(λint) = real(sum(subtract_tail(kintegrate(kG, χ_λ(χr, λint), 1)[1,:],EKin, iωn)))/mP.β  -EKin*mP.β/12 - rhs
    df(λint) = real(sum(kintegrate(kG, -χ_λ(χr, λint) .^ 2, 1)[1,:]))/mP.β

    nh  = ceil(Int64, size(χr,2)/2)
    χ_min = -minimum(1 ./ χr[:,nh])
    λsp = newton_right(f, df, χ_min)
    return λsp
end

function calc_λsp_correction(χ_in::AbstractArray{ComplexF64,2}, usable_ω::AbstractArray{Int64},
                            searchInterval::AbstractArray{Float64,1}, EKin::Float64,
                            rhs::Float64, kG::ReducedKGrid, mP::ModelParameters, sP::SimulationParameters)
    sh = DirectSum()
    χr    = real.(χ_in[:,usable_ω])
    iωn = 1im .* 2 .* (-sP.n_iω:sP.n_iω)[usable_ω] .* π ./ mP.β
    #TODO: this should use sum_freq instead of naiive sum()
    f(λint) = sum(subtract_tail(kintegrate(kG, χ_λ(χr, λint), 1)[1,:],EKin, iωn))/mP.β  -EKin*mP.β/12 - rhs
    df(λint) = sum(kintegrate(kG, -χ_λ(χr, λint) .^ 2, 1)[1,:])/mP.β

    nh    = ceil(Int64, size(χr,2)/2)
    χ_min    = -1 / maximum(χr[:,nh])
    λsp = newton_right(f, df, χ_min)
    @info "Found λsp " λsp
    return λsp, new_χλ(χ_in, λsp, sP)
end


#TODO: this is manually unrolled...
# after optimization, revert to:
# calc_Σ, correct Σ, calc G(Σ), calc E
function extended_λ(nlQ_sp::NonLocalQuantities, nlQ_ch::NonLocalQuantities, bubble::BubbleT, 
        Gνω::GνqT, FUpDo::AbstractArray{ComplexF64,3}, 
        Σ_loc_pos::AbstractArray{ComplexF64,1}, Σ_ladderLoc::AbstractArray{ComplexF64,1},
        kG::ReducedKGrid, mP::ModelParameters, sP::SimulationParameters)
    # --- prepare auxiliary vars ---
    ωindices = (sP.dbg_full_eom_omega) ? (1:size(bubble,1)) : intersect(nlQ_sp.usable_ω, nlQ_ch.usable_ω)

    νmax = trunc(Int,size(bubble,ν_axis)/3)
    νGrid = 0:(νmax-1)
    iν_n = iν_array(mP.β, νGrid)
    iωn = 1im .* 2 .* (-sP.n_iω:sP.n_iω)[ωindices] .* π ./ mP.β
    iωn2_sub = real.([i == 0 ? 0 : mP.Ekin_DMFT ./ (i).^2 for i in iωn])

    corr = Σ_correction(ωindices, bubble, FUpDo, sP)
    Σ_ladder_i = Array{Complex{Float64},2}(undef, size(bubble,1), νmax)
    χupdo_ω = Array{eltype(nlQ_sp.χ),1}(undef, length(ωindices))
    χupup_ω = Array{eltype(nlQ_sp.χ),1}(undef, length(ωindices))
    χsp_int = Array{eltype(nlQ_sp.χ),2}(undef, size(nlQ_sp.χ)...)
    χch_int = Array{eltype(nlQ_sp.χ),2}(undef, size(nlQ_sp.χ)...)

    # Prepare data
    corr = Σ_correction(ωindices, bubble, FUpDo, sP)
    (sP.tc_type_f != :nothing) && extend_corr!(corr)
    nh    = ceil(Int64, size(nlQ_sp.χ,2)/2)
    χsp_min    = -1 / maximum(real.(nlQ_sp.χ[:,nh]))
    χch_min    = -1 / maximum(real.(nlQ_ch.χ[:,nh]))

    Σ_hartree = mP.n * mP.U/2
    E_kin_tail_c = [zeros(size(kG.ϵkGrid)), (kG.ϵkGrid .+ Σ_hartree .- mP.μ)]
    E_pot_tail_c = [zeros(size(kG.ϵkGrid)),
                    (mP.U^2 * 0.5 * mP.n * (1-0.5*mP.n) .+ Σ_hartree .* (kG.ϵkGrid .+ Σ_hartree .- mP.μ))]
    tail = [1 ./ (iν_n .^ n) for n in 1:length(E_kin_tail_c)]
    E_pot_tail = sum(E_pot_tail_c[i]' .* tail[i] for i in 1:length(tail))
    E_pot_tail_inv = sum((mP.β/2)  .* [Σ_hartree .* ones(size(kG.ϵkGrid)), (-mP.β/2) .* E_pot_tail_c[2]])

    #TODO: also sum chi updo without arr
    #TODO: this part of the code is horrible but fast....
    function cond_both!(F, λ)
        lhs_c1 = 0.0
        lhs_c2 = 0.0
        nd = length(gridshape(kG))
        fill!(Σ_ladder_i, zero(eltype(Σ_ladder_i)))

        for ωii in 1:length(ωindices)
            ωi = ωindices[ωii]
            ωn = (ωi - sP.n_iω) - 1
        
            @inbounds fsp = 1.5 .* (1 .+ mP.U .* view(nlQ_sp.χ,:,ωi))
            @inbounds fch = 0.5 .* (1 .- mP.U .* view(nlQ_ch.χ,:,ωi))
            νZero = ν0Index_of_ωIndex(ωi, sP)
            maxn = minimum([νZero + νmax - 1, size(nlQ_ch.γ,ν_axis)])
            for (νi,νn) in enumerate(νZero:maxn)
                @simd for qi in 1:size(corr,q_axis)
                    @inbounds Kνωq_pre[qi] = nlQ_sp.γ[qi,νn,ωi] * fsp[qi] - nlQ_ch.γ[qi,νn,ωi] * fch[qi] - 1.5 + 0.5 + corr[qi,νn,ωii]
                end
                expandKArr!(kG,Kνωq,Kνωq_pre)
                Dispersions.mul!(Kνωq, kG.fftw_plan, Kνωq)
                v = selectdim(Gνω,nd+1,(νi-1) + ωn + sP.fft_offset)
                @simd for ki in 1:length(Kνωq)
                    @inbounds Kνωq[ki] *= v[ki]
                end
                Dispersions.ldiv!(Kνωq, kG.fftw_plan, Kνωq)
                Dispersions.ifft_post!(typeof(kG), Kνωq)
                reduceKArr!(kG, Kνωq_pre, Kνωq) 
                @simd for i in 1:size(corr,q_axis)
                @inbounds Σ_ladder_i[i,νi] += Kνωq_pre[i]/kG.Nk
                end
            end
            #TODO: end manual unroll of conv_fft1
            #@inbounds conv_fft!(kG, view(Σ,:,νn,ωii), Gνω[(νn-1) + ωn + sP.fft_offset], Kνωq)

            t1 = 0.0
            t2 = 0.0
            for qi in 1:length(kG.kMult)
                t1 += kG.kMult[qi]*real( 1.0 / ((1.0 / nlQ_ch.χ[qi,ωi]) .+ λ[2]))
                t2 += kG.kMult[qi]*real( 1.0 / ((1.0 / nlQ_sp.χ[qi,ωi]) .+ λ[1]))
            end
            lhs_c1 += (t1 + t2) / (2*kG.Nk) - iωn2_sub[ωii]
            lhs_c2 += (t1 - t2) / (2*kG.Nk)
            
        end
        E_pot = 0.0
        for qi in 1:length(kG.kMult)
            GΣ_λ = 0.0
            for i in 1:νmax
                Σ_λ = mP.U * Σ_ladder_i[qi,i]/mP.β + Σ_corr[i]
                GΣ_λ += 2 * real(Σ_λ * G_from_Σ(iν_n[i], mP.β, mP.μ, kG.ϵkGrid[qi], Σ_λ) - E_pot_tail[qi,i])
            end
            GΣ_λ += E_pot_tail_inv[qi]   # ν summation
            E_pot += kG.kMult[qi]*GΣ_λ # k intgration
        end
        E_pot = E_pot / (kG.Nk * mP.β)
        lhs_c1 = (lhs_c1 - mP.Ekin_DMFT*mP.β/12)/mP.β
        lhs_c2 = lhs_c2/mP.β
        rhs_c1 = mP.n/2 * (1 - mP.n/2)
        rhs_c2 = E_pot/mP.U - (mP.n/2) * (mP.n/2)
        F[1] = lhs_c1 - rhs_c1
        F[2] = lhs_c2 - rhs_c2
        return F
    end
    function cond_both(λ)
        F = zeros(size(λ)...)
        cond_both!(F,λ)
        return F
    end
    @info "searching for λsp_ch, starting from $χsp_min $χch_min"
    x0 = [χsp_min+1.0; χch_min+1.0]
    λ_new = newton_2d_right(cond_both, x0, nsteps=300, atol=1e-7)
    @info "found λsp = $(λ_new[1]), λch = $(λ_new[2])"
    return λ_new
end

function λsp_correction_search_int(χr::AbstractArray{Float64,2}, kG::ReducedKGrid, mP::ModelParameters; init=nothing, init_prct::Float64 = 0.1)
    nh    = ceil(Int64, size(χr,2)/2)
    χ_min    = -minimum(1 ./ χr[:,nh])
    int = if init === nothing
        rval = χ_min > 0 ? χ_min + 10/kG.Ns + 20/mP.β : minimum([20*abs(χ_min), χ_min + 10/kG.Ns + 20/mP.β])
        [χ_min, rval]
    else
        [init - init_prct*abs(init), init + init_prct*abs(init)]
    end
    @info "found " χ_min ". Looking for roots in intervall $(int)" 
    return int
end

function λ_correction(type::Symbol, impQ_sp, impQ_ch, FUpDo, Σ_loc_pos, Σ_ladderLoc, nlQ_sp::NonLocalQuantities, nlQ_ch::NonLocalQuantities, 
                      bubble::BubbleT, Gνω::GνqT, 
                      kG::ReducedKGrid,
                      mP::ModelParameters, sP::SimulationParameters; init_sp=nothing, init_spch=nothing)
    res = if type == :sp
        rhs,usable_ω_λc = calc_λsp_rhs_usable(impQ_sp, impQ_ch, nlQ_sp, nlQ_ch, kG, mP, sP)
        searchInterval_sp = λsp_correction_search_int(real.(nlQ_sp.χ[:,usable_ω_λc]), kG, mP, init=init_sp)
        searchInterval_spch = [-Inf, Inf]
        λsp,χsp_λ = calc_λsp_correction(nlQ_sp.χ, usable_ω_λc, searchInterval_sp, impQ_sp.tailCoeffs[3] , rhs, kG, mP, sP)
        λsp
    elseif type == :sp_ch
        extended_λ(nlQ_sp, nlQ_ch, bubble, Gνω, FUpDo, Σ_loc_pos, Σ_ladderLoc, kG, mP, sP)
    end
    return res
end

function λ_correction!(type::Symbol, impQ_sp, impQ_ch, FUpDo, Σ_loc_pos, Σ_ladderLoc, nlQ_sp::NonLocalQuantities, nlQ_ch::NonLocalQuantities, 
                      bubble::BubbleT, Gνω::GνqT, 
                      kG::ReducedKGrid,
                      mP::ModelParameters, sP::SimulationParameters; init_sp=nothing, init_spch=nothing)

    λ = λ_correction(type, impQ_sp, impQ_ch, FUpDo, Σ_loc_pos, Σ_ladderLoc, nlQ_sp, nlQ_ch, 
                  bubble, Gνω, kG, mP, sP; init_sp=init_sp, init_spch=init_spch)
    res = if type == :sp
        nlQ_sp.χ = SharedArray(χ_λ(nlQ_sp.χ, λ))
        nlQ_sp.λ = λ
    elseif type == :sp_ch
        nlQ_sp.χ = SharedArray(χ_λ(nlQ_sp.χ, λ[1]))
        nlQ_sp.λ = λ[1]
        nlQ_ch.χ = SharedArray(χ_λ(nlQ_ch.χ, λ[2]))
        nlQ_ch.λ = λ[2]
    end
end

function newton_right(f::Function, df::Function,
                            start::Float64; nsteps=5000, atol=1e-11)
    done = false
    δ = 0.1
    x0 = start + δ
    xi = x0
    i = 1
    while !done
        fi = f(xi)
        dfii = 1 / df(xi)
        xlast = xi
        xi = x0 - dfii * fi
        (norm(xi-x0) < atol) && break
        if xi < x0               # only ever search to the right!
            δ  = δ/2.0
            x0  = start + δ      # reset with smaller delta
            xi = x0
        else
            x0 = xi
        end
        (i >= nsteps ) && (done = true)
        i += 1
    end
    return xi
end

function newton_2d_right(f::Function, 
                start::Vector{Float64}; nsteps=500, atol=1e-6, max_x2=3.0)
    done = false
    δ = [0.1, 0.1]
    x0 = start .+ δ
    xi = x0
    i = 1
    cache = FiniteDiff.JacobianCache(xi)
    J2 = Matrix{Float64}(undef, 2,2)
    while !done
        fi = f(xi)
        dfii = inv(FiniteDiff.finite_difference_jacobian(f, xi, cache))
        xlast = xi
        xi = x0 - dfii * fi
        (norm(xi-x0) < atol) && break
        if xi[1] .< x0[1]        # only ever search to the right!
            println("reset")
            flush(stdout)
            δ  = δ .+ 0.2 .* δ
            x0 = start .+ δ      # reset with larger delta
            xi = x0
        elseif xi[2] > max_x2    # λch has some cutoff value, here just 0, later to be determined
            δ  = δ ./ 2 
            x0 = start .+ δ      # reset with smaller delta
            xi = x0
        else
            x0 = xi
        end
        (i >= nsteps ) && (done = true)
        i += 1
    end
    return xi
end
