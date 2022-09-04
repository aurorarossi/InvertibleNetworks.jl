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
    affine::Bool
end

@Flux.functor CouplingLayerGlow

# Constructor from 1x1 convolution and residual block
function CouplingLayerGlow(C::Conv1x1, RB::ResidualBlock; logdet=false, activation::ActivationFunction=SigmoidLayer())
    RB.fan == false && throw("Set ResidualBlock.fan == true")
    return CouplingLayerGlow(C, RB, logdet, activation, true)
end

# Constructor from 1x1 convolution and residual Flux block
CouplingLayerGlow(C::Conv1x1, RB::FluxBlock; logdet=false, activation::ActivationFunction=SigmoidLayer()) = CouplingLayerGlow(C, RB, logdet, activation, true)

# Constructor from input dimensions
function CouplingLayerGlow(n_in::Int64, n_hidden::Int64; affine=true, freeze_conv=false, k1=3, k2=1, p1=1, p2=0, s1=1, s2=1, logdet=false, activation::ActivationFunction=SigmoidLayer(), ndims=2)

    affine ? (n_out = n_in) : (n_out = Int(n_in/2))
    # 1x1 Convolution and residual block for invertible layer
    C = Conv1x1(n_in; freeze=freeze_conv)
    RB = ResidualBlock(Int(n_in/2), n_hidden; n_out=n_out, k1=k1, k2=k2, p1=p1, p2=p2, s1=s1, s2=s2, fan=true, ndims=ndims)

    return CouplingLayerGlow(C, RB, logdet, activation, affine)
end

CouplingLayerGlow3D(args...;kw...) = CouplingLayerGlow(args...; kw..., ndims=3)

# Forward pass: Input X, Output Y
function forward(X::AbstractArray{T, N},  L::CouplingLayerGlow;mask=nothing) where {T,N}

    X_ = L.C.forward(X)
    X1, X2 = tensor_split(X_; mask=mask)

    Y2 = copy(X2)
    if L.affine
        logS_T = L.RB.forward(X2)
        logSm, Tm = tensor_split(logS_T)
        Sm = L.activation.forward(logSm)
        Y1 = Sm .* X1 + Tm

        Y = tensor_cat(Y1, Y2; mask=mask)
        L.logdet == true ? (return Y, glow_logdet_forward(Sm)) : (return Y)
    else
        Tm = L.RB.forward(X2)
        Y1 = X1 + Tm
        Y = tensor_cat(Y1, Y2)
        L.logdet == true ? (return Y, T(0)) : (return Y)
    end
end

# Inverse pass: Input Y, Output X
function inverse(Y::AbstractArray{T, N}, L::CouplingLayerGlow; mask=nothing, save=false) where {T,N}
    Y1, Y2 = tensor_split(Y; mask=mask)
    X2 = copy(Y2)

    if L.affine
        logS_T = L.RB.forward(X2)
        logSm, Tm = tensor_split(logS_T)
        Sm = L.activation.forward(logSm)
        X1 = (Y1 - Tm) ./ (Sm .+ eps(T)) # add epsilon to avoid division by 0
    else
        Tm = L.RB.forward(X2)
        X1 = Y1 - Tm
        Sm = nothing 
    end
    X_ = tensor_cat(X1, X2; mask=mask)
    X = L.C.inverse(X_)

    save == true ? (return X, X1, X2, Sm) : (return X)
end

# Backward pass: Input (ΔY, Y), Output (ΔX, X)
function backward(ΔY::AbstractArray{T, N}, Y::AbstractArray{T, N},  L::CouplingLayerGlow; mask=nothing, set_grad::Bool=true) where {T,N}

    # Recompute forward state
    X, X1, X2, S = inverse(Y, L;mask=mask, save=true)

    # Backpropagate residual
    ΔY1, ΔY2 = tensor_split(ΔY; mask=mask)
    ΔT = copy(ΔY1)
    if L.affine #might be easier if we just set S to ones. Might simplify all the math 
        ΔS = ΔY1 .* X1
        if L.logdet
            set_grad ? (ΔS -= glow_logdet_backward(S)) : (ΔS_ = glow_logdet_backward(S))
        end
        ΔX1 = ΔY1 .* S
        ΔX2 = L.RB.backward(tensor_cat(L.activation.backward(ΔS, S), ΔT), X2) + ΔY2
    else
        ΔX1 = ΔY1 
        ΔX2 = L.RB.backward(ΔT, X2) + ΔY2
    end

    ΔX_ = tensor_cat(ΔX1, ΔX2; mask=mask)
    ΔX = L.C.inverse((ΔX_, tensor_cat(X1, X2; mask=mask)))[1]
   
  
    return ΔX, X
   
end


## Jacobian-related functions

function jacobian(ΔX::AbstractArray{T, N}, Δθ::Array{Parameter, 1}, X, L::CouplingLayerGlow) where {T,N}

    # Get dimensions
    k = Int(L.C.k/2)

    ΔX_, X_ = L.C.jacobian(ΔX, Δθ[1:3], X)
    X1, X2 = tensor_split(X_)
    ΔX1, ΔX2 = tensor_split(ΔX_)

    Y2 = copy(X2)
    ΔY2 = copy(ΔX2)
    ΔlogS_T, logS_T = L.RB.jacobian(ΔX2, Δθ[4:end], X2)
    Sm = L.activation.forward(logS_T[:,:,1:k,:])
    ΔS = L.activation.backward(ΔlogS_T[:,:,1:k,:], nothing;x=logS_T[:,:,1:k,:])
    Tm = logS_T[:, :, k+1:end, :]
    ΔT = ΔlogS_T[:, :, k+1:end, :]
    Y1 = Sm.*X1 + Tm
    ΔY1 = ΔS.*X1 + Sm.*ΔX1 + ΔT
    Y = tensor_cat(Y1, Y2)
    ΔY = tensor_cat(ΔY1, ΔY2)

    # Gauss-Newton approximation of logdet terms
    JΔθ = L.RB.jacobian(cuzeros(ΔX2, size(ΔX2)), Δθ[4:end], X2)[1][:, :, 1:k, :]
    GNΔθ = cat(0f0*Δθ[1:3], -L.RB.adjointJacobian(tensor_cat(L.activation.backward(JΔθ, Sm), zeros(Float32, size(Sm))), X2)[2]; dims=1)

    L.logdet ? (return ΔY, Y, glow_logdet_forward(Sm), GNΔθ) : (return ΔY, Y)
end

function adjointJacobian(ΔY::AbstractArray{T, N}, Y::AbstractArray{T, N}, L::CouplingLayerGlow) where {T, N}
    return backward(ΔY, Y, L; set_grad=false)
end

# Logdet (correct?)
glow_logdet_forward(S) = sum(log.(abs.(S))) / size(S)[end]
glow_logdet_backward(S) = 1f0./ S / size(S)[end]
