@testset "auxiliary functions" begin
    @test all(LadderDGA.reduce_range(1:3, 1.0) .== 2:2)
    @test all(LadderDGA.reduce_range(1:4, 1.0) .== 2:3)
    @test all(LadderDGA.reduce_range(1:5, 1.0) .== 3:3)
    @test all(LadderDGA.reduce_range(1:6, 1.0) .== 3:4)
    @test all(LadderDGA.reduce_range(1:10, 0.2) .== 2:9)
    @test all(LadderDGA.reduce_range(1:20, 0.1) .== 2:19)
    @test all(LadderDGA.reduce_range(1:21, 0.1) .== 2:20)
    @test all(LadderDGA.reduce_range(1:20, 0.5) .== 6:15)
    @test all(LadderDGA.reduce_range(1:21, 0.5) .== 6:16)
end
