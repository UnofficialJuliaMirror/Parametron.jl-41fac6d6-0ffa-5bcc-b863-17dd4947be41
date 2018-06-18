module LazyExpressionTest

using Compat
using Compat.Test
using SimpleQP
using StaticArrays

import SimpleQP: setdirty!, MockModel

@testset "basics" begin
    a = 2
    b = 3
    c = 4
    expr = @expression(a + b * c)
    @test expr() == a + b * c
end

@testset "bad expression" begin
    @test_throws(ArgumentError, @expression x ? y : z)
end

@testset "parameter" begin
    model = MockModel()
    a = 3
    b = 4.0
    cval = Ref(0)
    c = Parameter{Int}(() -> cval[], model)
    expr = @expression(a + b * c)

    @test expr() == a + b * cval[]
    cval[] = 4
    setdirty!(c)
    @test expr() == a + b * cval[]
end

@testset "nested" begin
    model = MockModel()
    a = 3
    b = 4.0
    cval = Ref(5)
    c = Parameter{Int}(() -> cval[], model)
    expr1 = @expression(a + b * c)
    expr2 = @expression(4 * expr1)
    @test expr2() == 4 * expr1()
    show(devnull, expr1)
end

module M
export SpatialMat, angular, linear
struct SpatialMat
    angular::Matrix{Float64}
    linear::Matrix{Float64}
end
angular(mat::SpatialMat) = mat.angular
linear(mat::SpatialMat) = mat.linear
end

using .M

@testset "user functions" begin
    mat = SpatialMat(rand(3, 4), rand(3, 4))
    scalar = Ref(1.0)
    updatemat! = let scalar = scalar # https://github.com/JuliaLang/julia/issues/15276
        mat -> (mat.angular .= scalar[]; mat.linear .= scalar[]; mat)
    end
    model = MockModel()
    pmat = Parameter(updatemat!, mat, model)
    pmat_angular = @expression angular(pmat)
    result = pmat_angular()
    @test result === angular(mat)
    @test all(result .== scalar[])

    setdirty!(model)
    allocs = @allocated begin
        setdirty!(model)
        pmat_angular()
    end
    @test allocs == 0
end

@testset "matvecmul!" begin
    m = MockModel()
    A = Parameter(rand!, zeros(3, 4), m)
    x = Variable.(1 : 4)
    expr = @expression A * x
    @test expr() == A() * x
    setdirty!(m)
    allocs = @allocated begin
        setdirty!(m)
        expr()
    end
    @test allocs == 0

    wrapped = SimpleQP.WrappedExpression{Vector{AffineFunction{Float64}}}(expr)
    setdirty!(m)
    @test wrapped() == expr()
    allocs = @allocated begin
        setdirty!(m)
        wrapped()
    end
    @test allocs == 0
end

@testset "StaticArrays" begin
    m = MockModel()
    A = Parameter{SMatrix{3, 3, Int, 9}}(m) do
        @SMatrix ones(Int, 3, 3)
    end
    x = Variable.(1 : 3)

    expr1 = @expression A * x
    @test expr1() == A() * x
    setdirty!(A)
    allocs = @allocated expr1()
    @test allocs == 0
    @test expr1() isa SVector{3, AffineFunction{Int}}

    y = SVector{3}(x)
    expr2 = @expression y + y
    @test expr2() == y + y
    allocs = @allocated expr2()
    @test allocs == 0
    @test expr2() isa SVector{3, AffineFunction{Int}}

    expr3 = @expression y - y
    @test expr3() == y - y
    allocs = @allocated expr3()
    @test allocs == 0
    @test expr3() isa SVector{3, AffineFunction{Int}}
end

@testset "mul! optimization" begin
    m = MockModel()
    weight = Parameter(() -> 3, m)
    x = Variable.(1 : 3)
    expr = @expression weight * (x ⋅ x)
    vals = Dict(zip(x, [1, 2, 3]))
    xvals = getindex.(vals, x)
    @test expr()(vals) == 3 * xvals ⋅ xvals
    allocs = @allocated expr()
    @test allocs == 0
end

@testset "vcat optimization" begin
    srand(42)
    m = MockModel()
    A = Parameter(rand!, zeros(3, 4), m)
    B = Parameter(rand!, zeros(3, 3), m)
    x = Variable.(1 : 4)
    y = Variable.(5 : 7)
    f1 = @expression A * x
    f2 = @expression B * y

    v1 = @expression vcat(f1, f2)
    @test v1() == vcat(f1(), f2())
    setdirty!(m)
    @test (@allocated begin
        setdirty!(m)
        v1()
    end) == 0

    # Make sure we expand vcat expressions
    v2 = @expression [f1; f2]
    @test v2() == vcat(f1(), f2())
    @test (@allocated begin
        setdirty!(m)
        v2()
    end) == 0

    # Make sure static arrays still work
    C = Parameter{SMatrix{2, 2, Int, 4}}(m) do
        @SMatrix [1 2; 3 4]
    end
    z = SVector(Variable(8), Variable(9))
    f3 = @expression C * z
    v3 = @expression [f3; f3]
    @test v3() == vcat(f3(), f3())
    @test v3() isa SVector{4, AffineFunction{Int}}
    @test (@allocated begin
        setdirty!(m)
        v3()
    end) == 0

    # Other numbers of arguments
    v4 = @expression vcat(f3)
    @test v4() == f3()
    @test (@allocated begin
        setdirty!(m)
        v4()
    end) == 0

    v5 = @expression vcat(f1, f2, f3)
    @test v5() == vcat(f1(), f2(), f3())
    @test (@allocated begin
        setdirty!(m)
        v5()
    end) == 0

    # Generic fallbacks that allocate memory but should still give the right answer
    @test (@expression vcat(x, y))() == vcat(x, y)
    @test (@expression vcat(f1, 3))() == vcat(f1(), 3)
    @test (@expression vcat(x', [1, 2, 3, 4]'))() == vcat(x', [1, 2, 3, 4]')
end

@testset "convert optimization" begin
    m = MockModel()
    A = Parameter{SMatrix{3, 3, Int, 9}}(m) do
        @SMatrix ones(Int, 3, 3)
    end
    x = Variable.(1 : 3)
    expr = @expression convert(Vector, A * x)

    @test expr() == A() * x
    @test expr() isa Vector{AffineFunction{Int}}
    allocs = @allocated expr()
    @test allocs == 0
end

end