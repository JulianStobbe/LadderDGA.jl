# ==================================================================================================== # 
#                                                                                                      #
#                                          Helper Functions                                            #
#                                                                                                      #
# ==================================================================================================== # 
function readConfig(file)
    tml = TOML.parsefile(file)
    model = 
    sim = tml["Simulation"]
    model = ModelParameters(tml["Model"]["U"], 
                            tml["Model"]["mu"], 
                            tml["Model"]["beta"], 
                            tml["Model"]["nden"],
                            tml["Model"]["Dimensions"])
    sim = SimulationParameters(tml["Simulation"]["nFermFreq"],
                               tml["Simulation"]["nBoseFreq"],
                               tml["Simulation"]["shift"],
                               tml["Simulation"]["Nk"],
                               tml["Simulation"]["NkInt"],
                               tml["Simulation"]["Nq"],
                               tml["Simulation"]["tail_corrected"],
                               tml["Simulation"]["chi_only"],
                               tml["Simulation"]["kInt"])
    env = EnvironmentVars(   tml["Environment"]["loadFortran"],
                             tml["Environment"]["writeFortran"],
                             tml["Environment"]["loadAsymptotics"],
                             tml["Environment"]["inputDir"],
                             tml["Environment"]["inputVars"],
                             tml["Environment"]["asymptVars"]
                            )
    return (model, sim, env)
end

function convertGF!(GF, storedInverse, storeFull)
    if storedInverse
        GF = 1 ./ GF
    end
    if storeFull
        NH = size(GF, 1)
        tmp = copy(GF)
        GF = Array{eltype(GF)}(undef, 2*NH - 1)
        GF[1:(NH-1)] = reverse(conj.(tmp[2:NH]))
        GF[NH:end] = tmp[1:NH]
    end
end

function print_chi_bubble(qList, res, simParams)
    for j in 1:size(res,1)
        print(" ========== ω = $(j-(simParams.n_iω + 1)) =============== \n")
        for k in 1:size(res,2)
            print(" ---------- ν = $(k-1) -------------- \n")
            for (qi,q) in enumerate(qList)
                @printf("   q = (%.2f,%.2f): %.2f + %.2fi\n", q[1],q[2], real(res[j, k, qi]), imag(res[j, k, qi]))
            end
        end
    end
end

function reduce_3Freq(inp, freqBox, simParams)
    n_iω = simParams.n_iω
    n_iν = simParams.n_iν
    start_ωₙ =  -(freqBox[1,1] + n_iω) + 1
    start_νₙ =  -(freqBox[2,1] + n_iν) + 2
    # This selects the range of [-ωₙ, ωₙ] and [-νₙ, νₙ-1] from gamma
    return inp[start_ωₙ:(start_ωₙ+2*n_iω), start_νₙ:(start_νₙ + 2*n_iν - 1), start_νₙ:(start_νₙ +2*n_iν - 1)]
end

reduce_3Freq!(inp, freqBox, simParams) = inp = reduce_3Freq(inp, freqBox, simParams)


function convert_from_fortran(simParams, env, loadFromBak=false)
    println("Reading Fortran Input, this can take several minutes.")
    if loadFromBak
        vars = load("fortran_files_bak") 
        g0 = vars["g0"]
        gImp = vars["gImp"]
        FreqBox = vars["freqBox"]
        Γcharge = vars["Gcharge"]
        Γspin = vars["Gspin"]
        χDMFTCharge = vars["cDMFTCharge"]
        χDMFTSpin = vars["cDMFTSpin"]
    else
        g0 = readFortranSymmGF(simParams.n_iν+simParams.n_iω, env.inputDir*"/g0mand", storedInverse=true)
        gImp = readFortranSymmGF(simParams.n_iν+simParams.n_iω, env.inputDir*"/gm_wim", storedInverse=false)
        freqBox, Γcharge, Γspin = readFortranΓ(env.inputDir*"/gamma_dir")
        println("Done Reading Gamma")
        χDMFTCharge, χDMFTSpin = readFortranχDMFT(env.inputDir*"/chi_dir")
        println("Done Reading chi")
    end
    Γcharge = -1.0 .* reduce_3Freq(Γcharge, freqBox, simParams)
    Γspin = -1.0 .* reduce_3Freq(Γspin, freqBox, simParams)
    χDMFTCharge = reduce_3Freq(χDMFTCharge, freqBox, simParams)
    χDMFTSpin = reduce_3Freq(χDMFTSpin, freqBox, simParams)
    if env.writeFortran
        println("Writing HDF5 (vars.jdl) and Fortran (fortran_out/) output.")
        writeFortranΓ("fortran_out", "gamma", simParams, Γcharge, Γspin)
        writeFortranΓ("fortran_out", "chi", simParams, 0.5 .* (χDMFTCharge .+ χDMFTSpin), 0.5 .* (χDMFTCharge .- χDMFTSpin))
    end
    if length(env.inputVars) > 0
        save(env.inputVars, "g0", g0, "gImp", gImp, "GammaCharge", Γcharge, "GammaSpin", Γspin,
             "chiDMFTCharge", χDMFTCharge, "chiDMFTSpin", χDMFTSpin, "freqBox", freqBox, compress=true, compatible=true)
    end
end

# ==================================================================================================== # 
#                                                                                                      #
#                                            Parquet Input                                             #
#                                                                                                      #
# ==================================================================================================== # 
function readFortranSymmGF_pq(nFreq, filename; storedInverse, storeFull=false)
    GF = redirect_stdout(open("/dev/null","w")) do
        load(filename) |> @orderby(_.__index_level_0__) |> @take(nFreq)|> @map((_.Re) + (_.Im)*1im) |> collect
    end
    convertGF!(GF, storedInverse, storeFull)
    println(GF)
    return GF
end

function readFortranΓ_pq(fileName::String)
    #in = redirect_stdout(open("/dev/null","w")) do
        #load(filename) |> @orderby(_.__index_level_0__, _.__index_level_1__)
    #end
    #ωₙ, freqBox, Γcharge0, Γspin0
    Γcharge = Array{Complex{Float64}}(undef, length(files), size(Γspin0,1), size(Γspin0,2))
    Γspin   = Array{Complex{Float64}}(undef, length(files), size(Γspin0,1), size(Γspin0,2))
    Γcharge[1,:,:] = Γcharge0
    Γspin[1,:,:]   = Γspin0 
    ω_min = ωₙ
    ω_max = ωₙ
    
    for (i,file) in enumerate(files[2:end])
        ωₙ, _, Γcharge_new, Γspin_new = readFortran3FreqFile(dirName * "/" * file, sign=-1.0)
        ω_min = if ωₙ < ω_min ωₙ else ω_min end
        ω_max = if ωₙ > ω_max ωₙ else ω_max end
        Γcharge[i,:,:] = Γcharge_new
        Γspin[i,:,:] = Γspin_new
    end
    freqBox = [ω_min ω_max; freqBox[1,1] freqBox[1,2]; freqBox[2,1] freqBox[2,2]]
    #Γcharge = permutedims(Γcharge, [3,1,2])
    #Γspin   = permutedims(Γspin, [3,1,2])
    return freqBox, Γcharge, Γspin
end

function readFortranχDMFT_pq(filename::String)
    in = redirect_stdout(open("/dev/null","w")) do
        load(filename) |> collect
    end
    #_, _, χup, χdown = readFortran3FreqFile(dirName * "/" * files[1], sign=1.0, freqInteger=false)

    for file in files[2:end]
        _, _, χup_new, χdown_new = readFortran3FreqFile(dirName * "/" * file, sign=1.0, freqInteger=false)
        χup = cat(χup, χup_new, dims=3)
        χdown = cat(χdown, χdown_new, dims=3)
    end
    χup = permutedims(χup, [3,1,2])
    χdown   = permutedims(χdown, [3,1,2])
    χCharge = χup .+ χdown
    χSpin   = χup .- χdown
    return χCharge, χSpin 
end

function convert_from_fortran_pq(simParams, env)
    println("Reading Fortran Parquet-File Input, this can take several minutes.")
    g0 = readFortranSymmGF_pq(simParams.n_iν+simParams.n_iω, env.inputDir*"/g0mand.parquet", storedInverse=true)
    gImp = readFortranSymmGF_pq(simParams.n_iν+simParams.n_iω, env.inputDir*"/gm_wim.parquet", storedInverse=false)
    χDMFTCharge, χDMFTSpin = readFortranχDMFT_pq(env.inputDir*"/vert_chi.parquet")
    freqBox, Γcharge, Γspin = readFortranΓ_pq(env.inputDir*"/GAMMA_DM_FULLRANGE.parquet")
    Γcharge = -1.0 .* reduce_3Freq(Γcharge, freqBox, simParams)
    Γspin = -1.0 .* reduce_3Freq(Γspin, freqBox, simParams)
    χDMFTCharge = reduce_3Freq(χDMFTCharge, freqBox, simParams)
    χDMFTSpin = reduce_3Freq(χDMFTSpin, freqBox, simParams)
    println("Writing HDF5 (vars.jdl) and Fortran (fortran_out/) output.")
    writeFortranΓ("fortran_out", "gamma", simParams, Γcharge, Γspin)
    writeFortranΓ("fortran_out", "chi", simParams, 0.5 .* (χDMFTCharge .+ χDMFTSpin), 0.5 .* (χDMFTCharge .- χDMFTSpin))
    save(env.inputVars, "g0", g0, "gImp", gImp, "GammaCharge", Γcharge, "GammaSpin", Γspin,
         "chiDMFTCharge", χDMFTCharge, "chiDMFTSpin", χDMFTSpin, "freqBox", freqBox, compress=true, compatible=true)
end


# ==================================================================================================== # 
#                                                                                                      #
#                                            Text Input                                                #
#                                                                                                      #
# ==================================================================================================== # 
function readFortran3FreqFile(filename; sign = 1.0, freqInteger = true)
    InString = open(filename, "r") do f
        readlines(f)
    end
    InArr = sign .* parse.(Float64,hcat(split.(InString)...)[2:end,:])
    N = Int(sqrt(size(InArr,2)))
    if freqInteger
        ωₙ = Int(parse(Float64, split(InString[1])[1]))
        middleFreqBox = Int64.([minimum(InArr[1,:]),maximum(InArr[1,:])])
        innerFreqBox  = Int64.([minimum(InArr[2,:]),maximum(InArr[2,:])])
        freqBox = permutedims([middleFreqBox innerFreqBox], [2,1])
    else
        #print("\rWarning, non integer frequencies in "*filename*" ignored!")
        ωₙ = 0
        freqBox = []
    end

    InCol1  = reshape(InArr[3,:] .+ InArr[4,:].*1im, (N, N))
    InCol2  = reshape(InArr[5,:] .+ InArr[6,:].*1im, (N, N))
    return ωₙ, freqBox, InCol1, InCol2
end

function readFortranqωFile(filename, nDims; readq = false, data_cols = 2)
    InString = open(filename, "r") do f
        readlines(f)
    end
    start = if readq 1 else nDims+1  end
    InArr = parse.(Float64,hcat(split.(InString)...)[start:end,:])
    if readq
        qVecArr = InArr[1:3,:]
    else
        qVecArr = []
        nDims = 0
    end
    data_λ = InArr[nDims+1,:] + InArr[nDims+2,:] .* 1im
    data = InArr[nDims+3,:] + InArr[nDims+4,:] .* 1im
    return qVecArr, data_λ, data
end

function readFortranΓ(dirName::String)
    files = readdir(dirName)
    ωₙ, freqBox, Γcharge0, Γspin0 = readFortran3FreqFile(dirName * "/" * files[1], sign=-1.0)
    Γcharge = Array{Complex{Float64}}(undef, length(files), size(Γspin0,1), size(Γspin0,2))
    Γspin   = Array{Complex{Float64}}(undef, length(files), size(Γspin0,1), size(Γspin0,2))
    Γcharge[1,:,:] = Γcharge0
    Γspin[1,:,:]   = Γspin0 
    ω_min = ωₙ
    ω_max = ωₙ
    
    for (i,file) in enumerate(files[2:end])
        ωₙ, _, Γcharge_new, Γspin_new = readFortran3FreqFile(dirName * "/" * file, sign=-1.0)
        ω_min = if ωₙ < ω_min ωₙ else ω_min end
        ω_max = if ωₙ > ω_max ωₙ else ω_max end
        Γcharge[i+1,:,:] = Γcharge_new
        Γspin[i+1,:,:] = Γspin_new
    end
    freqBox = [ω_min ω_max; freqBox[1,1] freqBox[1,2]; freqBox[2,1] freqBox[2,2]]
    Γcharge = permutedims(Γcharge, [1,3,2])
    Γspin   = permutedims(Γspin, [1,3,2])
    return freqBox, Γcharge, Γspin
end


"""
    Returns χ_DMFT[ω, ν, ν']
"""
function readFortranχDMFT(dirName::String)
    files = readdir(dirName)
    _, _, χupup, χupdo = readFortran3FreqFile(dirName * "/" * files[1], sign=1.0, freqInteger=false)

    for file in files[2:end]
        _, _, χup_new, χupdo_new = readFortran3FreqFile(dirName * "/" * file, sign=1.0, freqInteger=false)
        χupup = cat(χupup, χup_new, dims=3)
        χupdo = cat(χupdo, χupdo_new, dims=3)
    end
    χupup = permutedims(χupup, [3,2,1])
    χupdo   = permutedims(χupdo, [3,2,1])
    χCharge = χupup .+ χupdo
    χSpin   = χupup .- χupdo
    return χCharge, χSpin 
end

function readFortranχlDGA(dirName::String, nDims)
    files = readdir(dirName)
    qVecs, data_λ_i, data_i = readFortranqωFile(dirName * "/" * files[1], nDims, readq = true);
    data = Array{Complex{Float64}}(undef, length(files), 2, length(data_i))
    data[1,1,:] = data_λ_i
    data[1,2,:] = data_i
    for (i,file) in enumerate(files[2:end])
        _, data_λ_i, data_i = readFortranqωFile(dirName * "/" * file, nDims, readq = false);
        data[i+1,1,:] = data_λ_i
        data[i+1,2,:] = data_i
    end
    qVecs, data
end


function readFortranBubble(dirName::String, nBose, nFermi, nQ)
    bubble = Array{Complex{Float64}}(undef, nBose, nQ, nFermi)
    files_i = readdir(dirName)
    files = [dirName * "/" * f for f  in files_i]
    iBose = 1
    for file in files[1:end]
        InString = open(file, "r") do f
            readlines(f)
        end
        InArr = parse.(Float64,hcat(split.(InString)...)[4:end,:])
        bubble[iBose, :, :] = reshape(InArr[1,:] .+ InArr[2,:].*1im, (nQ, nFermi))
        iBose += 1
    end

    bubble = permutedims(bubble, [1,3,2])
    return bubble
end

function read_anderson_parameters(file)
    content = open(file) do f
        readlines(f)
    end
    
    in_epsk = false
    in_tpar = false
    ϵₖ = []
    Vₖ = []
    μ = 0
    for line in content
        if "Eps(k)" == strip(line)
            in_epsk = true
            continue
        elseif "tpar(k)" == strip(line)
            in_epsk = false
            in_tpar = true
            continue
        end
        
        if in_epsk
            push!(ϵₖ, parse(Float64, line))
        elseif in_tpar
            # skip last line, which is mu
            if length(Vₖ) < length(ϵₖ)
                push!(Vₖ, parse(Float64, line))
            else
                if occursin("#", line)
                    μ = parse(Float64, line[1:(findfirst("#", line))[1] - 1])
                else
                    μ = parse(Float64, line)
                end
            end
        end
    end
    return convert(Array{Float64,1}, ϵₖ), convert(Array{Float64,1}, Vₖ), μ
end

function readGImp(filename; only_positive=false)
    GFString = open(filename, "r") do f
        readlines(f)
    end


    tmp = parse.(Float64,hcat(split.(GFString)...)) # Construct a 2xN array of floats (re,im as 1st index)
    tmpG = tmp[2,:] .+ tmp[3,:].*1im
    tmpiνₙ = tmp[1,:] .* 1im
    if only_positive
        GImp = tmpG
        iνₙ  = tmpiνₙ
    else
        N = 2*size(tmpG,1)
        NH = size(tmpG,1)
        GImp = zeros(Complex{Float64}, N)
        iνₙ  = zeros(Complex{Float64}, N)
        GImp[1:(NH)] = reverse(conj.(tmpG[1:NH]))
        GImp[(NH+1):N] = tmpG[1:NH]
        iνₙ[1:(NH)] = conj.(reverse(tmpiνₙ[1:(NH)]))
        iνₙ[(NH+1):N] = tmpiνₙ[1:NH]
    end
    return iνₙ, GImp
end


function readEDAsymptotics(env)
    χ_asympt = readdlm(env.inputDir * "/chi_asympt")   
    χchAsympt = (χ_asympt[:,2] + χ_asympt[:,4]) / (2*modelParams.β*modelParams.β);
    χspAsympt = (χ_asympt[:,2] - χ_asympt[:,4]) / (2*modelParams.β*modelParams.β);
    #= _, χup, χdo = readFortranEDχ(env.inputDir * "/chi_dir", freqInteger = false) =#
    #= χchED = χup .+ χdo =#
    #= χspED = χup .- χdo =#
    save(env.asymptVars, "chi_ch_asympt", χchAsympt, "chi_sp_asympt", χspAsympt, 
         compress=true, compatible=true)
end

function readFortranSymmGF(nFreq, filename; storedInverse, storeFull=false)
    GFString = open(filename, "r") do f
        readlines(f)
    end

    if size(GFString, 1)*(1 + 1*storeFull) < nFreq
        throw(BoundsError("nFermFreq in simulation parameters too large!"))
    end
    
    tmp = parse.(Float64,hcat(split.(GFString)...)[2:end,:]) # Construct a 2xN array of floats (re,im as 1st index)
    tmp = tmp[1,:] .+ tmp[2,:].*1im

    if storedInverse
        tmp = 1 ./ tmp
    end
    
    GF = Array{Complex{Float64}}(undef, nFreq)
    if storeFull
        NH = Int(nFreq/2)
        GF[1:(NH-1)] = reverse(conj.(tmp[2:NH]))
        GF[NH:nFreq] = tmp[1:NH]
    else
        GF = tmp[1:nFreq]
    end
    return GF
end

function readFortran3FreqFile(filename; sign = 1.0, freqInteger = true)
    InString = open(filename, "r") do f
        readlines(f)
    end
    NCols = 7
    NRows = length(InString)
    lineLen = length(InString[1])
    splitLength = floor(Int64,lineLen/NCols)
    if lineLen%NCols != 0
        println(stderr, "   ---> Warning!! Could not find fixed column width!")
    end
    #InArr = sign .* parse.(Float64,hcat(split.(InString)...)[2:end,:])
    InArr = zeros(Float64, NRows, NCols-1)
    N = Int(sqrt(NRows))
    ErrorLine = []
    for i in 1:NRows
        row =  split_n(InString[i], splitLength, lineLen)[2:end]
        for j in 1:(NCols-1)
            InArr[i,j] = try
                sign * parse(Float64,row[j])
            catch e
                NaN
            end
        end
    end
    if freqInteger
        ωₙ = Int(parse(Float64, split(InString[1])[1]))
        tmpArr1 = filter(!isnan,InArr[:,1])
        tmpArr2 = filter(!isnan,InArr[:,2])
        middleFreqBox = Int64.([minimum(tmpArr1),maximum(tmpArr1)])
        innerFreqBox  = Int64.([minimum(tmpArr2),maximum(tmpArr2)])
        freqBox = permutedims([middleFreqBox innerFreqBox], [2,1])
    else
        #print("\rWarning, non integer frequencies in "*filename*" ignored!")
        ωₙ = 0
        freqBox = []
    end

    InCol1  = reshape(InArr[:,3] .+ InArr[:,4].*1im, (N, N))
    InCol2  = reshape(InArr[:,5] .+ InArr[:,6].*1im, (N, N))
    return ωₙ, freqBox, InCol1, InCol2
end




# ==================================================================================================== # 
#                                                                                                      #
#                                            Text Output                                                #
#                                                                                                      #
# ==================================================================================================== # 
function writeFortranΓ(dirName::String, fileName::String, simParams, inCol1, inCol2)
    simParams.n_iν+simParams.n_iω
    if !isdir(dirName)
        mkdir(dirName)
    end
    for (ωi,ωₙ) in enumerate(-simParams.n_iω:simParams.n_iω)
        filename = dirName * "/" * fileName * lpad(ωi-1,3,"0")
        open(filename, "w") do f
            for (νi,νₙ) in enumerate(-simParams.n_iν:(simParams.n_iν-1))
                for (ν2i,ν2ₙ) in enumerate(-simParams.n_iν:(simParams.n_iν-1))
                    @printf(f, "%18.10f  %18.10f  %18.10f %18.10f %18.10f %18.10f %18.10f\n", ωₙ, νₙ, ν2ₙ,
                            real(inCol1[ωi, νi, ν2i]), imag(inCol1[ωi, νi, ν2i]), 
                            real(inCol2[ωi, νi, ν2i]), imag(inCol2[ωi, νi, ν2i]))
                end
            end
        end
    end
end
