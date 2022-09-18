module LadderDGA

    include("DepsInit.jl")

    export kintegrate
    export ModelParameters, SimulationParameters, EnvironmentVars
    export LocalQuantities, ΓT, χ₀T, χT, γT, GνqT, FUpDoT
    export readConfig, setup_LDGA, calc_bubble, calc_χγ, calc_Σ_ω, calc_Σ, calc_Σ_parts, calc_Σνω, calc_λ0, Σ_loc_correction, filling
    export calc_bubble_par, calc_χγ_par, calc_Σ_par
    export λsp, λ_correction, λ_correction!, calc_λsp_rhs_usable, calc_λsp_correction!, c2_curve, find_root
    export λ_from_γ, F_from_χ, G_from_Σ, GLoc_from_Σladder
    export calc_E, calc_Epot2
    export χ_λ, χ_λ!, subtract_tail, subtract_tail!

end
