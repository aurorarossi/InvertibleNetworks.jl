# Invertible network layer from Putzky and Welling (2019): https://arxiv.org/abs/1911.10914
# Author: Philipp Witte, pwitte3@gatech.edu
# Date: January 2020

export CouplingLayerIRIM

"""
    IL = CouplingLayerIRIM(C::Conv1x1, RB::ResidualBlock)

or

    IL = CouplingLayerIRIM(nx, ny, n_in, n_hidden, batchsize; k1=4, k2=3, p1=0, p2=1, s1=4, s2=1, logdet=false) (2D)

    IL = CouplingLayerIRIM(nx, ny, nz, n_in, n_hidden, batchsize; k1=4, k2=3, p1=0, p2=1, s1=4, s2=1, logdet=false) (3D)


 Create an i-RIM invertible coupling layer based on 1x1 convolutions and a residual block. 

 *Input*: 
 
 - `C::Conv1x1`: 1x1 convolution layer
 
 - `RB::ResidualBlock`: residual block layer consisting of 3 convolutional layers with ReLU activations.

 or

 - `nx`, `ny`, `nz`: spatial dimensions of input
 
 - `n_in`, `n_hidden`: number of input and hidden channels

 - `k1`, `k2`: kernel size of convolutions in residual block. `k1` is the kernel of the first and third 
    operator, `k2` is the kernel size of the second operator.

 - `p1`, `p2`: padding for the first and third convolution (`p1`) and the second convolution (`p2`)

 - `s1`, `s2`: stride for the first and third convolution (`s1`) and the second convolution (`s2`)

 *Output*:
 
 - `IL`: Invertible i-RIM coupling layer.

 *Usage:*

 - Forward mode: `Y = IL.forward(X)`

 - Inverse mode: `X = IL.inverse(Y)`

 - Backward mode: `ΔX, X = IL.backward(ΔY, Y)`

 *Trainable parameters:*

 - None in `IL` itself

 - Trainable parameters in residual block `IL.RB` and 1x1 convolution layer `IL.C`

 See also: [`Conv1x1`](@ref), [`ResidualBlock!`](@ref), [`get_params`](@ref), [`clear_grad!`](@ref)
"""
struct CouplingLayerIRIM <: NeuralNetLayer
    C::Conv1x1
    RB::Union{ResidualBlock, FluxBlock}
end

@Flux.functor CouplingLayerIRIM

# 2D Constructor from input dimensions
function CouplingLayerIRIM(nx::Int64, ny::Int64, n_in::Int64, n_hidden::Int64, batchsize::Int64; 
    k1=4, k2=3, p1=0, p2=1, s1=4, s2=1)

    # 1x1 Convolution and residual block for invertible layer
    C = Conv1x1(n_in)
    RB = ResidualBlock(nx, ny, Int(n_in/2), n_hidden, batchsize; k1=k1, k2=k2, p1=p1, p2=p2, s1=s1, s2=s2)

    return CouplingLayerIRIM(C, RB)
end

# 3D Constructor from input dimensions
function CouplingLayerIRIM(nx::Int64, ny::Int64, nz::Int64, n_in::Int64, n_hidden::Int64, batchsize::Int64; 
    k1=4, k2=3, p1=0, p2=1, s1=4, s2=1)

    # 1x1 Convolution and residual block for invertible layer
    C = Conv1x1(n_in)
    RB = ResidualBlock(nx, ny, nz, Int(n_in/2), n_hidden, batchsize; k1=k1, k2=k2, p1=p1, p2=p2, s1=s1, s2=s2)

    return CouplingLayerIRIM(C, RB)
end

# 2D Forward pass: Input X, Output Y
function forward(X::AbstractArray{Float32, 4}, L::CouplingLayerIRIM)

    # Get dimensions
    k = Int(L.C.k/2)
    
    X_ = L.C.forward(X)
    X1_ = X_[:, :, 1:k, :]
    X2_ = X_[:, :, k+1:end, :]

    Y1_ = X1_
    Y2_ = X2_ + L.RB.forward(Y1_)
    
    Y_ = cat(Y1_, Y2_, dims=3)
    Y = L.C.inverse(Y_)
    
    return Y
end

# 3D Forward pass: Input X, Output Y
function forward(X::AbstractArray{Float32, 5}, L::CouplingLayerIRIM)

    # Get dimensions
    k = Int(L.C.k/2)
    
    X_ = L.C.forward(X)
    X1_ = X_[:, :, :, 1:k, :]
    X2_ = X_[:, :, :, k+1:end, :]

    Y1_ = X1_
    Y2_ = X2_ + L.RB.forward(Y1_)
    
    Y_ = cat(Y1_, Y2_, dims=4)
    Y = L.C.inverse(Y_)
    
    return Y
end

# 2D Inverse pass: Input Y, Output X
function inverse(Y::AbstractArray{Float32, 4}, L::CouplingLayerIRIM; save=false)

    # Get dimensions
    k = Int(L.C.k/2)

    Y_ = L.C.forward(Y)
    Y1_ = Y_[:, :, 1:k, :]
    Y2_ = Y_[:, :, k+1:end, :]
    
    X1_ = Y1_
    X2_ = Y2_ - L.RB.forward(Y1_)
    
    X_ = cat(X1_, X2_, dims=3)
    X = L.C.inverse(X_)
    
    if save == false
        return X
    else
        return X, X_, Y1_
    end
end

# 3D Inverse pass: Input Y, Output X
function inverse(Y::AbstractArray{Float32, 5}, L::CouplingLayerIRIM; save=false)

    # Get dimensions
    k = Int(L.C.k/2)

    Y_ = L.C.forward(Y)
    Y1_ = Y_[:, :, :, 1:k, :]
    Y2_ = Y_[:, :, :, k+1:end, :]
    
    X1_ = Y1_
    X2_ = Y2_ - L.RB.forward(Y1_)
    
    X_ = cat(X1_, X2_, dims=4)
    X = L.C.inverse(X_)
    
    if save == false
        return X
    else
        return X, X_, Y1_
    end
end


# 2D Backward pass: Input (ΔY, Y), Output (ΔX, X)
function backward(ΔY::AbstractArray{Float32, 4}, Y::AbstractArray{Float32, 4}, L::CouplingLayerIRIM; set_grad::Bool=true)

    # Recompute forward state
    k = Int(L.C.k/2)
    X, X_, Y1_ = inverse(Y, L; save=true)

    # Backpropagate residual
    if set_grad
        ΔY_ = L.C.forward((ΔY, Y))[1]
    else
        ΔY_, Δθ_C1 = L.C.forward((ΔY, Y); set_grad=set_grad)[1:2]
    end
    ΔY2_ = ΔY_[:, :, k+1:end, :]
    if set_grad
        ΔY1_ = L.RB.backward(ΔY2_, Y1_) + ΔY_[:, :, 1:k, :]
    else
        ΔY1__, Δθ_RB = L.RB.backward(ΔY2_, Y1_; set_grad=set_grad)
        ΔY1_ = ΔY1__ + ΔY_[:, :, 1:k, :]
    end
    
    ΔX_ = cat(ΔY1_, ΔY2_, dims=3)
    if set_grad
        ΔX = L.C.inverse((ΔX_, X_))[1]
    else
        ΔX, Δθ_C2 = L.C.inverse((ΔX_, X_); set_grad=set_grad)[1:2]
    end
    
    set_grad ? (return ΔX, X) : (return ΔX, cat(Δθ_C1+Δθ_C2, Δθ_RB; dims=1), X)
end

# 3D Backward pass: Input (ΔY, Y), Output (ΔX, X)
function backward(ΔY::AbstractArray{Float32, 5}, Y::AbstractArray{Float32, 5}, L::CouplingLayerIRIM; set_grad::Bool=true)

    # Recompute forward state
    k = Int(L.C.k/2)
    X, X_, Y1_ = inverse(Y, L; save=true)

    # Backpropagate residual
    if set_grad
        ΔY_ = L.C.forward((ΔY, Y))[1]
    else
        ΔY_, Δθ_C1 = L.C.forward((ΔY, Y); set_grad=set_grad)[1:2]
    end
    ΔY2_ = ΔY_[:, :, :, k+1:end, :]
    if set_grad
        ΔY1_ = L.RB.backward(ΔY2_, Y1_) + ΔY_[:, :, :, 1:k, :]
    else
        ΔY1__, Δθ_RB = L.RB.backward(ΔY2_, Y1_; set_grad=set_grad)
        ΔY1_ = ΔY1__ + ΔY_[:, :, :, 1:k, :]
    end
    
    ΔX_ = cat(ΔY1_, ΔY2_, dims=4)
    if set_grad
        ΔX = L.C.inverse((ΔX_, X_))[1]
    else
        ΔX, Δθ_C2 = L.C.inverse((ΔX_, X_); set_grad=set_grad)[1:2]
    end
    
    set_grad ? (return ΔX, X) : (return ΔX, cat(Δθ_C1+Δθ_C2, Δθ_RB; dims=1), X)
end


## Jacobian utilities

# 2D
function jacobian(ΔX::AbstractArray{Float32, 4}, Δθ::Array{Parameter, 1}, X::AbstractArray{Float32, 4}, L::CouplingLayerIRIM)

    # Get dimensions
    k = Int(L.C.k/2)
    
    ΔX_, X_ = L.C.jacobian(ΔX, Δθ[1:3], X)
    X1_ = X_[:, :, 1:k, :]
    ΔX1_ = ΔX_[:, :, 1:k, :]
    X2_ = X_[:, :, k+1:end, :]
    ΔX2_ = ΔX_[:, :, k+1:end, :]

    Y1_ = X1_
    ΔY1_ = ΔX1_
    ΔY1__, Y1__ = L.RB.jacobian(ΔY1_, Δθ[4:end], Y1_)
    Y2_ = X2_ + Y1__
    ΔY2_ = ΔX2_ + ΔY1__
    
    Y_ = cat(Y1_, Y2_, dims=3)
    ΔY_ = cat(ΔY1_, ΔY2_, dims=3)
    ΔY, Y = L.C.jacobianInverse(ΔY_, Δθ[1:3], Y_)
    
    return ΔY, Y

end

# 3D
function jacobian(ΔX::AbstractArray{Float32, 5}, Δθ::Array{Parameter, 1}, X::AbstractArray{Float32, 5}, L::CouplingLayerIRIM)

    # Get dimensions
    k = Int(L.C.k/2)
    
    ΔX_, X_ = L.C.jacobian(ΔX, Δθ[1:3], X)
    X1_ = X_[:, :, :, 1:k, :]
    ΔX1_ = ΔX_[:, :, :, 1:k, :]
    X2_ = X_[:, :, :, k+1:end, :]
    ΔX2_ = ΔX_[:, :, :, k+1:end, :]

    Y1_ = X1_
    ΔY1_ = ΔX1_
    ΔY1__, Y1__ = L.RB.jacobian(ΔY1_, Δθ[4:end], Y1_)
    Y2_ = X2_ + Y1__
    ΔY2_ = ΔX2_ + ΔY1__
    
    Y_ = cat(Y1_, Y2_, dims=4)
    ΔY_ = cat(ΔY1_, ΔY2_, dims=4)
    ΔY, Y = L.C.jacobianInverse(ΔY_, Δθ[1:3], Y_)
    
    return ΔY, Y

end

# 2D/3D
function adjointJacobian(ΔY::AbstractArray{Float32, N}, Y::AbstractArray{Float32, N}, L::CouplingLayerIRIM) where N
    return backward(ΔY, Y, L; set_grad=false)
end


## Other utils

# Clear gradients
function clear_grad!(L::CouplingLayerIRIM)
    clear_grad!(L.C)
    clear_grad!(L.RB)
end

# Get parameters
function get_params(L::CouplingLayerIRIM)
    p1 = get_params(L.C)
    p2 = get_params(L.RB)
    return cat(p1, p2; dims=1)
end