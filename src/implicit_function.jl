"""
    ImplicitFunction{F,C,L}

Differentiable wrapper for an implicit function `x -> ŷ(x)` whose output is defined by explicit conditions `F(x,ŷ(x)) = 0`.

We can obtain the Jacobian of `ŷ` with the implicit function theorem:
```
∂₁F(x,ŷ(x)) + ∂₂F(x,ŷ(x)) * ∂ŷ(x) = 0
```
If `x ∈ ℝⁿ`, `y ∈ ℝᵐ` and `F(x,y) ∈ ℝᶜ`, this amounts to solving the linear system `A * J = B`, where `A ∈ ℝᶜᵐ`, `B ∈ ℝᶜⁿ` and `J ∈ ℝᵐⁿ`.

# Fields:
- `forward::F`: callable of the form `x -> ŷ(x)`
- `conditions::C`: callable of the form `(x,y) -> F(x,y)`
- `linear_solver::L`: callable of the form `(A,b) -> u` such that `A * u = b`
"""
Base.@kwdef struct ImplicitFunction{F,C,L}
    forward::F
    conditions::C
    linear_solver::L
end

struct SolverFailureException <: Exception
    msg::String
end

"""
    implicit(x)

Make [`ImplicitFunction`](@ref) callable by applying `implicit.forward`.
"""
(implicit::ImplicitFunction)(x) = first(implicit.forward(x))

"""
    frule(rc, (_, dx), implicit, x)

Custom forward rule for [`ImplicitFunction`](@ref).

We compute the Jacobian-vector product `Jv` by solving `Au = Bv` and setting `Jv = u`.
"""
function ChainRulesCore.frule(
    rc::RuleConfig, (_, dx), implicit::ImplicitFunction, x::AbstractVector
)
    (; forward, conditions, linear_solver) = implicit

    y, useful_info = forward(x)
    n, m = length(x), length(y)

    conditions_x(x̃) = conditions(x̃, y, useful_info)
    conditions_y(ỹ) = -conditions(x, ỹ, useful_info)

    pushforward_A(dỹ) = frule_via_ad(rc, (NoTangent(), dỹ), conditions_y, y)[2]
    pushforward_B(dx̃) = frule_via_ad(rc, (NoTangent(), dx̃), conditions_x, x)[2]

    mul_A!(res, v) = res .= pushforward_A(v)
    mul_B!(res, v) = res .= pushforward_B(v)

    A = LinearOperator(Float64, m, m, false, false, mul_A!)
    B = LinearOperator(Float64, m, n, false, false, mul_B!)

    dx_vec = Vector(unthunk(dx))
    b = B * dx_vec
    dy_vec, stats = linear_solver(A, b)
    if !stats.solved
        throw(SolverFailureException("The linear solver failed to converge"))
    end
    return y, dy_vec
end

"""
    rrule(rc, implicit, x)

Custom reverse rule for [`ImplicitFunction`](@ref).

We compute the vector-Jacobian product `Jᵀv` by solving `Aᵀu = v` and setting `Jᵀv = Bᵀu`.
"""
function ChainRulesCore.rrule(rc::RuleConfig, implicit::ImplicitFunction, x::AbstractVector)
    (; forward, conditions, linear_solver) = implicit

    y, useful_info = forward(x)
    n, m = length(x), length(y)

    conditions_x(x̃) = conditions(x̃, y, useful_info)
    conditions_y(ỹ) = -conditions(x, ỹ, useful_info)

    pullback_Aᵀ = last ∘ rrule_via_ad(rc, conditions_y, y)[2]
    pullback_Bᵀ = last ∘ rrule_via_ad(rc, conditions_x, x)[2]

    mul_Aᵀ!(res, v) = res .= pullback_Aᵀ(v)
    mul_Bᵀ!(res, v) = res .= pullback_Bᵀ(v)

    Aᵀ = LinearOperator(Float64, m, m, false, false, mul_Aᵀ!)
    Bᵀ = LinearOperator(Float64, n, m, false, false, mul_Bᵀ!)

    function implicit_pullback(dy)
        dy_vec = Vector(unthunk(dy))
        u, stats = linear_solver(Aᵀ, dy_vec)
        if !stats.solved
            throw(SolverFailureException("The linear solver failed to converge"))
        end
        dx_vec = Bᵀ * u
        return (NoTangent(), dx_vec)
    end

    return y, implicit_pullback
end
