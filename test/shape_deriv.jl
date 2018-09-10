using FemMesh, LinearAlgebra
using Test

printstyled("\nShape functions\n", color=:cyan)

for shape in ALL_SHAPES
    print("shape : ", shape.name)
    n  = shape.npoints
    ndim = shape.ndim

    In = Matrix{Float64}(I,n,n)

    # Check at nodes
    RR = [ shape.nat_coords[i,:] for i=1:n ]
    NN = shape.func.(RR)

    II = hcat(NN...) # should provida an identity matrix
    @test II ≈ In atol=1e-10

    # Check at default set of integration points
    Q  = shape.quadrature[0]
    nip, _ = size(Q)
    #@show Q
    RR = [ Q[i,:] for i=1:nip ]
    NN = shape.func.(RR)
    @test sum(sum(NN)) ≈ nip atol=1e-10
    println("  ok")
end

printstyled("\nShape functions derivatives\n", color=:cyan)

for shape in ALL_SHAPES
    print("shape : ", shape.name)
    n    = shape.npoints
    ndim = shape.ndim
    RR = [ shape.nat_coords[i,:] for i=1:n ]
    f  = shape.func

    In = Matrix{Float64}(I,n,n)
    Id = Matrix{Float64}(I,ndim,ndim)

    # numerical derivative
    δ  = 1e-8
    for R in RR
        RI = R .+ Id*δ
        fR = f(R)
        D  = zeros(ndim, n)
        for i=1:ndim
            Di     = 1/δ*(f(RI[:,i]) - fR)
            D[i,:] = Di
        end
        @test D ≈ shape.deriv(R) atol=1e-6
    end
    println("  ok")
end
