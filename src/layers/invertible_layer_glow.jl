# Affine coupling layer from Dinh et al. (2017)
# Includes 1x1 convolution from in Putzky and Welling (2019)
# Author: Philipp Witte, pwitte3@gatech.edu
# Date: January 2020

export CouplingLayerGlow, CouplingLayerGlow3D


"""
    CL = CouplingLayerGlow(C::Conv1x1, RB::ResidualBlock; logdet=false)

or

    CL = CouplingLayerGlow(n_in, n_hidden; k1=3, k2=1, p1=1, p2=0, s1=1, s2=1, logdet=false, ndims=2) (2D)

    CL = CouplingLayerGlow(n_in, n_hidden; k1=3, k2=1, p1=1, p2=0, s1=1, s2=1, logdet=false, ndims=3) (3D)
    
    CL = CouplingLayerGlow3D(n_in, n_hidden; k1=3, k2=1, p1=1, p2=0, s1=1, s2=1, logdet=false) (3D)

 Create a Real NVP-style invertible coupling layer based on 1x1 convolutions and a residual block.

 *Input*:

 - `C::Conv1x1`: 1x1 convolution layer

 - `RB::ResidualBlock`: residual block layer consisting of 3 convolutional layers with ReLU activations.

 - `logdet`: bool to indicate whether to compte the logdet of the layer

 or

 - `n_in`, `n_hidden`: number of input and hidden channels

 - `k1`, `k2`: kernel size of convolutions in residual block. `k1` is the kernel of the first and third
    operator, `k2` is the kernel size of the second operator.

 - `p1`, `p2`: padding for the first and third convolution (`p1`) and the second convolution (`p2`)

 - `s1`, `s2`: stride for the first and third convolution (`s1`) and the second convolution (`s2`)

 - `ndims` : number of dimensions

 *Output*:

 - `CL`: Invertible Real NVP coupling layer.

 *Usage:*

 - Forward mode: `Y, logdet = CL.forward(X)`    (if constructed with `logdet=true`)

 - Inverse mode: `X = CL.inverse(Y)`

 - Backward mode: `ΔX, X = CL.backward(ΔY, Y)`

 *Trainable parameters:*

 - None in `CL` itself

 - Trainable parameters in residual block `CL.RB` and 1x1 convolution layer `CL.C`

 See also: [`Conv1x1`](@ref), [`ResidualBlock`](@ref), [`get_params`](@ref), [`clear_grad!`](@ref)
"""
struct CouplingLayerGlow <: NeuralNetLayer
    C::Conv1x1
    RB::Union{ResidualBlock, FluxBlock}
    logdet::Bool
    activation::ActivationFunction
end

@Flux.functor CouplingLayerGlow

# Constructor from 1x1 convolution and residual block
function CouplingLayerGlow(C::Conv1x1, RB::ResidualBlock; logdet=false, activation::ActivationFunction=SigmoidLayer())
    RB.fan == false && throw("Set ResidualBlock.fan == true")
    return CouplingLayerGlow(C, RB, logdet, activation)
end

# Constructor from 1x1 convolution and residual Flux block
CouplingLayerGlow(C::Conv1x1, RB::FluxBlock; logdet=false, activation::ActivationFunction=SigmoidLayer()) = CouplingLayerGlow(C, RB, logdet, activation)

# Constructor from input dimensions
function CouplingLayerGlow(n_in::Int64, n_hidden::Int64; freeze_conv=false, k1=3, k2=1, p1=1, p2=0, s1=1, s2=1, logdet=false, activation::ActivationFunction=SigmoidLayer(), ndims=2)

    # 1x1 Convolution and residual block for invertible layer
    C = Conv1x1(n_in; freeze=freeze_conv)
    RB = ResidualBlock(Int(n_in/2), n_hidden; k1=k1, k2=k2, p1=p1, p2=p2, s1=s1, s2=s2, fan=true, ndims=ndims)

    return CouplingLayerGlow(C, RB, logdet, activation)
end

CouplingLayerGlow3D(args...;kw...) = CouplingLayerGlow(args...; kw..., ndims=3)

# Forward pass: Input X, Output Y
function forward(X::AbstractArray{T, N}, L::CouplingLayerGlow; save=false) where {T,N}

    X_ = L.C.forward(X)
    X1, X2 = tensor_split(X_)

    logS_T = L.RB.forward(X2)
    logSm, Tm = tensor_split(logS_T)
    Sm = L.activation.forward(logSm)
    Y1 = Sm.*X1 + Tm

    Y = tensor_cat(Y1, X2)

    if L.logdet
        save ? (return Y, Y1, X2, coupling_logdet_forward(Sm), Sm) : (return Y, coupling_logdet_forward(Sm))
    else
        save ? (return Y, Y1, X2, Sm) : (return Y)
    end

end

# Inverse pass: Input Y, Output X
function inverse(Y::AbstractArray{T, N}, L::CouplingLayerGlow; save=false) where {T,N}
    Y1, Y2 = tensor_split(Y)

    X2 = copy(Y2)
    logS_T = L.RB.forward(X2)
    logSm, Tm = tensor_split(logS_T)
    Sm = L.activation.forward(logSm)
    X1 = (Y1 - Tm) ./ (Sm .+ eps(T)) # add epsilon to avoid division by 0

    X_ = tensor_cat(X1, X2)
    X = L.C.inverse(X_)

    save == true ? (return X, X1, X2, Sm) : (return X)
end

# Backward pass: Input (ΔY, Y), Output (ΔX, X)
function backward(ΔY::AbstractArray{T, N}, Y::AbstractArray{T, N}, L::CouplingLayerGlow; set_grad::Bool=true) where {T,N}

    # Recompute forward state
    X, X1, X2, S = inverse(Y, L; save=true)

    # Backpropagate residual
    ΔY1, ΔY2 = tensor_split(ΔY)
    ΔT = copy(ΔY1)
    ΔS = ΔY1 .* X1
    if L.logdet
        set_grad ? (ΔS -= glow_logdet_backward(S)) : (ΔS_ = glow_logdet_backward(S))
    end

    ΔX1 = ΔY1 .* S
    if set_grad
        ΔX2 = L.RB.backward(tensor_cat(L.activation.backward(ΔS, S), ΔT), X2) + ΔY2
    else
        ΔX2, Δθrb = L.RB.backward(tensor_cat(L.activation.backward(ΔS, S), ΔT; ), X2; set_grad=set_grad)
        _, ∇logdet = L.RB.backward(tensor_cat(L.activation.backward(ΔS_, S), 0f0.*ΔT;), X2; set_grad=set_grad)
        ΔX2 += ΔY2
    end
    ΔX_ = tensor_cat(ΔX1, ΔX2)
    if set_grad
        ΔX = L.C.inverse((ΔX_, tensor_cat(X1, X2)))[1]
    else
        ΔX, Δθc = L.C.inverse((ΔX_, tensor_cat(X1, X2)); set_grad=set_grad)[1:2]
        Δθ = cat(Δθc, Δθrb; dims=1)
    end

    if set_grad
        return ΔX, X
    else
        L.logdet ? (return ΔX, Δθ, X, cat(0*Δθ[1:3], ∇logdet; dims=1)) : (return ΔX, Δθ, X)
    end
end

# 2D/3D Reverse backward pass: Input (ΔX, X), Output (ΔY, Y)
function backward_inv(ΔX::AbstractArray{T, N}, X::AbstractArray{T, N}, L::CouplingLayerGlow; set_grad::Bool=true) where {T, N}

    ΔX, X = L.C.forward((ΔX, X))
    X1, X2 = tensor_split(X)
    ΔX1, ΔX2 = tensor_split(ΔX)

    # Recompute forward state
    #Y, Y1, X2, S = forward(X, L; save=true)
    logS_T = L.RB.forward(X2)
    logSm, Tm = tensor_split(logS_T)
    Sm = L.activation.forward(logSm)
    Y1 = Sm.*X1 + Tm

    # Backpropagate residual
    ΔT = -ΔX1 ./ Sm
    ΔS =  X1 .* ΔT 
    if L.logdet == true
        ΔS += coupling_logdet_backward(Sm)
    end

    ΔY2 = L.RB.backward(tensor_cat(L.activation.backward(ΔS, Sm), ΔT), X2) + ΔX2
    ΔY1 = -ΔT

    ΔY = tensor_cat(ΔY1, ΔY2)
    Y  = tensor_cat(Y1, X2)

    return ΔY, Y
end

## Jacobian-related functions
function jacobian(ΔX::AbstractArray{T, N}, Δθ::Array{Parameter, 1}, X, L::CouplingLayerGlow) where {T,N}

    ΔX_, X_ = L.C.jacobian(ΔX, Δθ[1:3], X)
    X1, X2 = tensor_split(X_)
    ΔX1, ΔX2 = tensor_split(ΔX_)

    Y2 = copy(X2)
    ΔY2 = copy(ΔX2)
    ΔlogS_T, logS_T = L.RB.jacobian(ΔX2, Δθ[4:end], X2)
    logSm, Tm = tensor_split(logS_T)
    ΔlogSm, ΔT = tensor_split(ΔlogS_T)

    Sm = L.activation.forward(logSm)
    ΔS = L.activation.backward(ΔlogSm, nothing;x=logSm)
    Y1 = Sm.*X1 + Tm
    ΔY1 = ΔS.*X1 + Sm.*ΔX1 + ΔT
    Y = tensor_cat(Y1, Y2)
    ΔY = tensor_cat(ΔY1, ΔY2)

    # Gauss-Newton approximation of logdet terms
    JΔθ = L.RB.jacobian(cuzeros(ΔX2, size(ΔX2)), Δθ[4:end], X2)[1]
    JΔθ = tensor_split(JΔθ)[1]
    GNΔθ = cat(0f0*Δθ[1:3], -L.RB.adjointJacobian(tensor_cat(L.activation.backward(JΔθ, Sm), zeros(Float32, size(Sm))), X2)[2]; dims=1)

    L.logdet ? (return ΔY, Y, glow_logdet_forward(Sm), GNΔθ) : (return ΔY, Y)
end

function adjointJacobian(ΔY::AbstractArray{T, N}, Y::AbstractArray{T, N}, L::CouplingLayerGlow) where {T, N}
    return backward(ΔY, Y, L; set_grad=false)
end

# Logdet (correct?)
glow_logdet_forward(S) = sum(log.(abs.(S))) / size(S)[end]
glow_logdet_backward(S) = 1f0./ S / size(S)[end]
