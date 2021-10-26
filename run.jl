using JLD2, FileIO

println("Modules loaded")
flush(stdout)
flush(stderr)

function run_sim(; descr="", cfg_file=nothing, res_prefix="", res_postfix="", save_results=true, log_io=devnull)
    @warn "assuming linear, continuous nu grid for chi/trilex"

    @timeit LadderDGA.to "read" mP, sP, env, kGridsStr = readConfig(cfg_file);


    for kIteration in 1:length(kGridsStr)
        @info "Running calculation for $(kGridsStr[kIteration])"
        @timeit LadderDGA.to "setup" impQ_sp, impQ_ch, gImp, kGridLoc, kG, gLoc, gLoc_fft, Σ_loc, FUpDo = setup_LDGA(kGridsStr[kIteration], mP, sP, env);

        @info "local"
        @timeit LadderDGA.to "loc bbl" bubbleLoc = calc_bubble(gImp, kGridLoc, mP, sP);
        @info "bbl done"
        @timeit LadderDGA.to "loc xsp" locQ_sp = calc_χ_trilex(impQ_sp.Γ, bubbleLoc, kGridLoc, mP.U, mP, sP);
        @info "xsp done"
        @timeit LadderDGA.to "loc xch"  locQ_ch = calc_χ_trilex(impQ_ch.Γ, bubbleLoc, kGridLoc, -mP.U, mP, sP);
        @info "xch done"

        @timeit LadderDGA.to "loc Σ" Σ_ladderLoc = calc_Σ(locQ_sp, locQ_ch, bubbleLoc, gImp, FUpDo, kGridLoc, mP, sP)

        flush(log_io)
        # ladder quantities
        @info "non local bubble"
        flush(log_io)
        @timeit LadderDGA.to "nl bblt" bubble = calc_bubble(gLoc_fft, kG, mP, sP);
        @info "chi sp"
        flush(log_io)
        @timeit LadderDGA.to "nl xsp" nlQ_sp = calc_χ_trilex(impQ_sp.Γ, bubble, kG, mP.U, mP, sP);
        @info "chi ch"
        flush(log_io)
        @timeit LadderDGA.to "nl xch" nlQ_ch = calc_χ_trilex(impQ_ch.Γ, bubble, kG, -mP.U, mP, sP);

        @info "λsp"
        flush(log_io)
        imp_density = real(impQ_sp.χ_loc + impQ_ch.χ_loc)
        λsp_old = λ_correction(:sp, imp_density, FUpDo, Σ_loc, Σ_ladderLoc, nlQ_sp, nlQ_ch,bubble, gLoc_fft, kG, mP, sP)
        @info "found $λsp_old\nextended λ"
        λ_new = 0.0#λ_correction(:sp_ch, impQ_sp, impQ_ch, FUpDo, Σ_loc, Σ_ladderLoc, nlQ_sp, nlQ_ch,bubble, gLoc_fft, kG, mP, sP)
        @info "found $λ_new\nλch_curve"
        flush(log_io)

        @timeit LadderDGA.to "lsp(lch)" λch_range, spOfch = λsp_of_λch(nlQ_sp, nlQ_ch, kG, mP, sP; λch_max=20.0, n_λch=10)

        @timeit LadderDGA.to "c2" λsp_of_λch_res = c2_along_λsp_of_λch(λch_range, spOfch, nlQ_sp, nlQ_ch, bubble,
                        Σ_ladderLoc, Σ_loc, gLoc_fft, FUpDo, kG, mP, sP)
    # Prepare data

        flush(log_io)
        tc_s = (sP.tc_type_f != :nothing) ? "rtc" : "ntc"
        fname = res_prefix*"lDGA_"*tc_s*"_k$(kG.Ns)_ext_l"*res_postfix*".jld2"
        @info "Writing to $(fname)"
        @timeit LadderDGA.to "write" jldopen(fname, "w") do f
            f["Description"] = descr
            f["config"] = read(cfg_file, String)
            f["kIt"] = kIteration  
            f["Nk"] = kG.Nk
            f["sP"] = sP
            f["mP"] = mP
            f["kG_loc"] = kGridLoc
            f["bubble_loc"] = bubbleLoc
            f["locQ_sp"] = locQ_sp
            f["locQ_ch"] = locQ_ch
            f["Sigma_loc"] = Σ_ladderLoc
            f["bubble"] = bubble
            f["nlQ_sp"] = nlQ_sp
            f["nlQ_ch"] = nlQ_ch
            f["λsp_old"] = λsp_old
            f["λch_range"] = λch_range
            f["spOfch"] = spOfch
            f["λsp_of_λch_res"] = λsp_of_λch_res
            #TODO: save log string
            #f["log"] = string()
        end
        @info "Runtime for iteration:"
        @info LadderDGA.to
    end
    @info "Done! Runtime:"
    print(LadderDGA.to)
end

function run2(cfg_file)
    run_sim(cfg_file=cfg_file)
end
