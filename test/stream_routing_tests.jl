using ReTest
using Kaimon

@testset "job_stash payload split" begin
    @test Kaimon._split_stash("loss=0.25") == ("loss", "0.25")
    @test Kaimon._split_stash("x∞=1") == ("x∞", "1")
    @test Kaimon._split_stash("∞=√2") == ("∞", "√2")
    @test Kaimon._split_stash("expr=a=b") == ("expr", "a=b")
    @test Kaimon._split_stash("key=") == ("key", "")
    @test Kaimon._split_stash("no separator") === nothing
end
