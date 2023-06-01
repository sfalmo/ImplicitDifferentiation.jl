using ChainRulesCore
using ChainRulesTestUtils
using ForwardDiff
using ImplicitDifferentiation
using JET
using LinearAlgebra
using Random
using Test
using Zygote

Random.seed!(63);

"""
    mysqrt(x)

Compute the elementwise square root, breaking Zygote.jl and ForwardDiff.jl in the process.
"""
function mysqrt(x::AbstractArray)
    a = [0.0]
    a[1] = first(x)
    return sqrt.(x)
end

myval(::Val{X}) where {X} = X

function make_implicit_sqrt(::Val{handle_byproduct}) where {handle_byproduct}
    if handle_byproduct
        forward_byproduct(x) = (mysqrt(x), 0)
        conditions_byproduct(x, y, z) = y .^ 2 .- x
        implicit = ImplicitFunction(forward_byproduct, conditions_byproduct, Val(true))
    else
        forward(x) = mysqrt(x)
        conditions(x, y) = y .^ 2 .- x
        implicit = ImplicitFunction(forward, conditions)
    end
    return implicit
end

for handle_byproduct in (Val(true), Val(false))
    testsetname = myval(handle_byproduct) ? "With byproduct" : "Without byproduct"
    @testset "$testsetname" verbose = true begin
        implicit = make_implicit_sqrt(handle_byproduct)
        # Skipped because of https://github.com/JuliaDiff/ChainRulesTestUtils.jl/issues/232 and because it detects weird type instabilities
        @testset verbose = true "ChainRulesTestUtils.jl" begin
            @test_skip test_rrule(implicit, x)
            @test_skip test_rrule(implicit, X)
        end

        @testset verbose = true "Vectors" begin
            x = rand(2)
            y = implicit(x)
            J = Diagonal(0.5 ./ sqrt.(x))

            @testset "Call" begin
                @test (@inferred implicit(x)) ≈ sqrt.(x)
                if VERSION >= v"1.7"
                    test_opt(implicit, (typeof(x),))
                end
            end

            @testset verbose = true "Forward" begin
                @test ForwardDiff.jacobian(implicit, x) ≈ J
                x_and_dx = ForwardDiff.Dual.(x, ((0, 0),))
                for return_byproduct in (true, false)
                    res_and_dres = @inferred implicit(x_and_dx, Val(return_byproduct))
                    if return_byproduct
                        y_and_dy, z = res_and_dres
                        @test size(y_and_dy) == size(y)
                    else
                        y_and_dy = res_and_dres
                        @test size(y_and_dy) == size(y)
                    end
                end
            end

            @testset "Reverse" begin
                @test Zygote.jacobian(implicit, x)[1] ≈ J
                for return_byproduct in (true, false)
                    _, pullback = @inferred rrule(
                        Zygote.ZygoteRuleConfig(), implicit, x, Val(return_byproduct)
                    )
                    dy, dz = zero(implicit(x)), 0
                    if return_byproduct
                        @test (@inferred pullback((dy, dz))) == pullback((dy, dz))
                        _, dx = pullback((dy, dz))
                        @test size(dx) == size(x)
                    else
                        @test (@inferred pullback(dy)) == pullback(dy)
                        _, dx = pullback(dy)
                        @test size(dx) == size(x)
                    end
                end
            end
        end

        @testset verbose = true "Arrays" begin
            X = rand(2, 3, 4)
            Y = implicit(X)
            JJ = Diagonal(0.5 ./ sqrt.(vec(X)))

            @testset "Call" begin
                @test (@inferred implicit(X)) ≈ sqrt.(X)
                if VERSION >= v"1.7"
                    test_opt(implicit, (typeof(X),))
                end
            end

            @testset "Forward" begin
                @test ForwardDiff.jacobian(implicit, X) ≈ JJ
                X_and_dX = ForwardDiff.Dual.(X, ((0, 0),))
                for return_byproduct in (true, false)
                    res_and_dres = @inferred implicit(X_and_dX, Val(return_byproduct))
                    if return_byproduct
                        Y_and_dY, Z = res_and_dres
                        @test size(Y_and_dY) == size(Y)
                    else
                        Y_and_dY = res_and_dres
                        @test size(Y_and_dY) == size(Y)
                    end
                end
            end

            @testset "Reverse" begin
                @test Zygote.jacobian(implicit, X)[1] ≈ JJ
                for return_byproduct in (true, false)
                    _, pullback = @inferred rrule(
                        Zygote.ZygoteRuleConfig(), implicit, X, Val(return_byproduct)
                    )
                    dY, dZ = zero(implicit(X)), 0
                    if return_byproduct
                        @test (@inferred pullback((dY, dZ))) == pullback((dY, dZ))
                        _, dX = pullback((dY, dZ))
                        @test size(dX) == size(X)
                    else
                        @test (@inferred pullback(dY)) == pullback(dY)
                        _, dX = pullback(dY)
                        @test size(dX) == size(X)
                    end
                end
            end
        end
    end
end
