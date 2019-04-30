#using FemMesh
#export mplot

const MOVETO = 1
const LINETO = 2
const CURVE3 = 3
const CURVE4 = 4
const CLOSEPOLY = 79

function plot_data_for_cell2d(points::Array{Array{Float64,1},1}, shape::ShapeType)

    if shape==LIN2
        verts = points
        codes = [ MOVETO, LINETO ]
    elseif shape == LIN3
        p1, p2, p3 = points
        cp    = 2*p3 - 0.5*p1 - 0.5*p2
        verts = [ p1, cp, p2 ]
        codes = [ MOVETO, CURVE3, CURVE3]
    elseif shape in (TRI3, QUAD4)
        n = shape==TRI3 ? 3 : 4
        codes = [ MOVETO ]
        verts = [ points[1] ]
        for i=1:n
            p2 = i<n ? points[i+1] : points[1]
            push!(verts, p2)
            push!(codes, LINETO)
        end
    elseif shape in (TRI6, QUAD8, QUAD9)
        n = shape==TRI6 ? 3 : 4
        codes = [ MOVETO ]
        verts = [ points[1] ]
        for i=1:n
            p1 = points[i]
            p2 = i<n ? points[i+1] : points[1]
            p3 = points[i+n]
            cp = 2*p3 - 0.5*p1 - 0.5*p2
            append!(verts, [cp, p2])
            append!(codes, [CURVE3, CURVE3])
        end
    elseif shape in (QUAD12, QUAD16)
        n = 4
        codes = [ MOVETO ]
        verts = [ points[1] ]
        for i=1:n
            p1 = points[i]
            p2 = i<n ? points[i+1] : points[1]
            p3 = points[2*i+3]
            p4 = points[2*i+4]
            cp2 = 1/6*(-5*p1+18*p2-9*p3+2*p4)
            cp3 = 1/6*( 2*p1-9*p2+18*p3-5*p4)
            append!(verts, [cp2, cp3, p2])
            append!(codes, [CURVE4, CURVE4, CURVE4])
        end
    else
        error("plot_data_for_cell2d: Not implemented for ", shape)
    end

    return verts, codes
end

function plot_data_for_cell3d(points::Array{Array{Float64,1},1}, shape::ShapeType)
    if shape == LIN2
        verts = points
    elseif shape in (TRI3, QUAD4)
        verts = points
    elseif shape == TRI6
        verts = points[[1,4,2,5,3,6]]
    elseif shape == QUAD8
        verts = points[[1,5,2,6,3,7,4,8]]
    end
    return verts
end


function mplot(items::Union{Block, Array}, filename::String=""; args...)
    # Get list of blocks and check type
    blocks = unfold(items) # only close if not saving to file

    for item in blocks
        isa(item, Block) || error("mplot: Block object expected")
    end

    # Using Point and Cell types
    points = Array{Point,1}()
    cells  = Array{Cell,1}()

    for bl in blocks
        append!(points, bl.points)

        if bl.shape.family==SOLID_SHAPE
            cell = Cell(bl.shape, bl.points)
            push!(cells, cell)
        elseif bl.shape.family==LINE_SHAPE
            lines = [ Cell(LIN2, bl.points[i-1:i]) for i=2:length(bl.points)]
            append!(cells, lines)
        else
            continue
        end

    end

    # Get ndim
    ndim = 1
    for point in points
        point.y != 0.0 && (ndim=2)
        point.z != 0.0 && (ndim=3; break)
    end

    mesh = Mesh()
    mesh.ndim = ndim
    mesh.points = points
    mesh.cells  = cells
    mplot(mesh, filename; args...)
end


function get_main_edges(cells::Array{Cell,1}, angle=30)
    edge_dict  = Dict{UInt64,Cell}()
    faces_dict = Dict{UInt64,Int}( hash(f)=>i for (i,f) in enumerate(cells) )
    get_main_edges = Cell[]
    # Get faces normals
    normals = [ get_facet_normal(f) for f in cells ]

    # Get only edges with almost coplanar adjacent planes
    for face in cells
        face.shape.family == SOLID_SHAPE || continue # only surface cells
        face_idx = faces_dict[hash(face)]
        for edge in get_edges(face)
            hs = hash(edge)
            edge0 = get(edge_dict, hs, nothing)
            if edge0==nothing
                edge_dict[hs] = edge
            else
                delete!(edge_dict, hs)
                n1 = normals[face_idx] # normal from face
                face0_idx = faces_dict[hash(edge0.ocell)]
                n2 = normals[face0_idx] # normal from edge0's parent
                α =acos( abs(min(dot(n1,n2),1)) )*180/pi
                α>angle && push!(get_main_edges, edge)
            end
        end
    end

    return get_main_edges

end


function get_facet_normal(face::Cell)
    ndim = 1 + face.shape.ndim
    C = getcoords(face, ndim)

    if ndim==2
        C .+= [pi pi^1.1]
    else
        C .+= [pi pi^1.1 pi^1.2]
    end

    # calculate the normal
    I = ones(size(C,1))
    N = pinv(C)*I # best fit normal
    normalize!(N) # get unitary vector

    return N
end


using PyCall # required

function mplot(mesh::Mesh, filename::String=""; axis=true, lw=0.5,
               pointmarkers=false, pointlabels=false, celllabels=false, alpha=1.0, 
               field=nothing, fieldscale=1.0, fieldlims=nothing, 
               vectorfield=nothing, arrowscale=0.0,
               cmap=nothing, colorbarscale=0.9, colorbarlabel="", colorbarpad=0.0,
               warpscale=0.0, highlightcell=0, elev=30.0, azim=45.0, dist=10.0,
               mainedges=false, edgeangle=30, figsize=(4,2.5), leaveopen=false)

    # Get initial info from mesh
    ndim = mesh.ndim
    if ndim==2
        point_scalar_data = mesh.point_scalar_data
        cell_scalar_data  = mesh.cell_scalar_data
        point_vector_data = mesh.point_vector_data
        points  = mesh.points
        cells   = mesh.cells
        connect = [ Int[ p.id for p in c.points ] for c in cells ]
    else
        point_scalar_data = Dict{String,Array}()
        cell_scalar_data  = Dict{String,Array}()
        point_vector_data = Dict{String,Array}()

        # get surface cells and update
        scells = get_surface(mesh.cells)  # TODO: add line cells
        spoints = [ p for c in scells for p in c.points ]
        pt_ids = [ p.id for p in spoints ]
        oc_ids = [ c.ocell.id for c in scells ]

        # update data
        for (field, data) in mesh.point_scalar_data
            point_scalar_data[field] = data[pt_ids]
        end
        for (field, data) in mesh.cell_scalar_data
            cell_scalar_data[field] = data[oc_ids]
        end
        for (field, data) in mesh.point_vector_data
            point_vector_data[field] = data[pt_ids, :]
        end

        # points and cells
        points = spoints
        cells  = scells

        # connectivities
        id_dict = Dict{Int, Int}( p.id => i for (i,p) in enumerate(points) )
        connect = [ Int[ id_dict[p.id] for p in c.points ] for c in cells ]
    end

    ncells  = length(cells)
    npoints = length(points)
    pts = [ [p.x, p.y, p.z] for p in points ]
    XYZ = [ pts[i][j] for i=1:npoints, j=1:3]


    # Lazy import of PyPlot
    @eval import PyPlot:plt, matplotlib, figure, art3D, Axes3D, ioff
    @eval ioff()

    # fix PyPlot
    @eval import PyPlot:getproperty, LazyPyModule
    if ! @eval hasmethod(getproperty, (LazyPyModule, AbstractString))
        @eval Base.getproperty(lm::LazyPyModule, s::AbstractString) = getproperty(PyCall.PyObject(lm), s)
    end

    plt.close("all")

    plt.rc("font", family="serif", size=7)
    plt.rc("lines", lw=0.5)
    plt.rc("legend", fontsize=7)
    plt.rc("figure", figsize=figsize) # suggested size (4.5,3)

    # All points coordinates
    if warpscale>0
        found = haskey(point_vector_data, "U")
        found || error("mplot: vector field U not found for warp")
        XYZ .+= warpscale.*point_vector_data["U"]
    end
    X = XYZ[:,1]
    Y = XYZ[:,2]
    Z = XYZ[:,3]

    limX = collect(extrema(X))
    limY = collect(extrema(Y))
    limZ = collect(extrema(Z))
    limX = limX + 0.05*[-1, 1]*norm(limX)
    limY = limY + 0.05*[-1, 1]*norm(limY)
    limZ = limZ + 0.05*[-1, 1]*norm(limZ)
    L = max(norm(limX), norm(limY), norm(limZ))

    # Configure plot
    if ndim==3
        ax = @eval Axes3D(figure())
        ax.set_aspect("equal")
        
        # Set limits
        meanX = mean(limX)
        meanY = mean(limY)
        meanZ = mean(limZ)
        limX = [meanX-L/2, meanX+L/2]
        limY = [meanY-L/2, meanY+L/2]
        limZ = [meanZ-L/2, meanZ+L/2]
        ax.set_xlim( meanX-L/2, meanX+L/2)
        ax.set_ylim( meanY-L/2, meanY+L/2)
        ax.set_zlim( meanZ-L/2, meanZ+L/2)
        #ax.scatter](limX, limY, limZ, color="w", marker="o", alpha=0.0)

        # Labels
        ax.set_xlabel("x")
        ax.set_ylabel("y")
        ax.set_zlabel("z")

        if axis == false
            ax.set_axis_off()
        end
    else
        ax = plt.gca()
        plt.axes().set_aspect("equal", "datalim")

        # Set limits
        ax.set_xlim(limX[1], limX[2])
        ax.set_ylim(limY[1], limY[2])

        # Labels
        ax.set_xlabel.("x")
        ax.set_ylabel.("y")
        if axis == false
            plt.axis("off")
        end
    end

    if cmap==nothing # cmap may be "bone", "plasma", "inferno", etc.
        #cm = colors.ListedColormap([(1,0,0),(0,1,0),(0,0,1)],256)
        #colors =  matplotlib.colors]
        #cm = matplotlib.colors].ListedColormap]([(1,0,0),(0,1,0),(0,0,1)],256)

        cdict = Dict("red"   => [(0.0,  0.8, 0.8), (0.5, 0.7, 0.7), (1.0, 0.0, 0.0)],
                     "green" => [(0.0,  0.2, 0.2), (0.5, 0.7, 0.7), (1.0, 0.2, 0.2)],
                     "blue"  => [(0.0,  0.0, 0.0), (0.5, 0.7, 0.7), (1.0, 0.6, 0.6)])

        cmap = matplotlib.colors.LinearSegmentedColormap("my_colormap",cdict,256)
    end

    has_field = field != nothing
    if has_field
        colorbarlabel = colorbarlabel=="" ? field : colorbarlabel
        field = string(field)
        found = haskey(cell_scalar_data, field)
        if found
            fvals = cell_scalar_data[field]
        else
            found = haskey(point_scalar_data, field)
            found || error("mplot: field $field not found")
            data  = point_scalar_data[field]
            fvals = [ mean(data[connect[i]]) for i=1:ncells ]
        end
        fvals *= fieldscale
        fieldlims==nothing && (fieldlims = extrema(fvals))
    end

    # Plot cells
    if ndim==3
        # Plot line cells
        for i=1:ncells 
            cells[i].shape.family == LINE_SHAPE || continue # only line cells
            con = cells[i]
            X = XYZ[con, 1]
            Y = XYZ[con, 2]
            Z = XYZ[con, 3]
            plt.plot(X, Y, Z, color="red", lw=1.0)
        end

        # Plot main edges and surface cells
        all_verts  = []

        # Plot surface cells
        for i=1:ncells 
            shape = cells[i].shape
            shape.family == SOLID_SHAPE || continue # only surface cells
            con = connect[i]
            points = [ XYZ[i,1:3] for i in con ]
            verts = plot_data_for_cell3d(points, shape)
            push!(all_verts, verts)
        end

        edgecolor = (0.3, 0.3, 0.3, 0.65)

        # Plot main edges
        if mainedges
            edges = get_main_edges(cells, edgeangle)
            θ, γ = (azim+0)*pi/180, elev*pi/180
            ΔX = [ cos(θ)*cos(γ), sin(θ)*cos(γ), sin(γ) ]*0.01*L
 
            for edge in edges
                p1 = edge.points[1]
                p2 = edge.points[2]
                verts = [ [ p1.x, p1.y, p1.z ], [ p2.x, p2.y, p2.z ] ]
                for v in verts
                    v .+= ΔX
                end
                push!(all_verts, verts)
            end
            edgecolor = [ fill((0.3, 0.3, 0.3, 0.65), ncells) ; fill((0.25, 0.25, 0.25, 1.0), length(edges)) ]
        end

        cltn = @eval art3D[:Poly3DCollection]($all_verts, cmap=$cmap, facecolor="aliceblue", edgecolor=$edgecolor, lw=$lw, alpha=$alpha)

        if has_field
            if mainedges
                fvals = [ fvals; fill(mean(fvals), length(edges)) ]
            end

            cltn.set_array(fvals)
            cltn.set_clim(fieldlims)
            #cbar = plt.colorbar(cltn, label=field, shrink=0.9)
            cbar = plt.colorbar(cltn, label=colorbarlabel, shrink=colorbarscale, aspect=10*colorbarscale*figsize[2], format="%.1f", pad=colorbarpad)
            cbar.ax.tick_params(labelsize=7)
            cbar.outline.set_linewidth(0.0)
            cbar.locator = matplotlib.ticker.MaxNLocator(nbins=8)
            cbar.update_ticks()
        end
        @eval $ax.add_collection3d($cltn)


    else
        all_patches = []
        for i=1:ncells
            shape = cells[i].shape
            shape.family == SOLID_SHAPE || continue # only surface cells
            
            con = connect[i]
            points = [ XYZ[i,1:2] for i in con ]
            verts, codes = plot_data_for_cell2d(points, shape)
            path  = matplotlib.path.Path(verts, codes)
            patch = matplotlib.patches.PathPatch(path)
            push!(all_patches, patch)

            if highlightcell==i
                patch = matplotlib.patches.PathPatch(path, facecolor="cadetblue", edgecolor="black", lw=0.5)
                ax.add_patch(patch)
            end
        end
        
        edgecolor = (0.3, 0.3 ,0.3, 0.6)
        cltn = matplotlib.collections.PatchCollection(all_patches, cmap=cmap, edgecolor=edgecolor, facecolor="aliceblue", lw=lw)
        if has_field
            cltn.set_array(fvals)
            cltn.set_clim(fieldlims)
            cbar = plt.colorbar(cltn, label=colorbarlabel, shrink=colorbarscale, aspect=0.9*20*colorbarscale, format="%.1f")
            cbar.ax.tick_params(labelsize=7)
            cbar.outline.set_linewidth(0.0)
            cbar.locator = matplotlib.ticker.MaxNLocator(nbins=8)
            cbar.update_ticks()
        end
        ax.add_collection(cltn)
    end

    # Draw points
    if pointmarkers
        if ndim==3
            ax.scatter(X, Y, Z, color="k", marker="o", s=1)
        else
            plt.plot(X, Y, color="black", marker="o", markersize=3, lw=0)
        end
    end

    # Draw arrows
    if vectorfield!=nothing && ndim==2
        data = point_vector_data[vectorfield]
        color = "blue"
        if arrowscale==0
            plt.quiver(X, Y, data[:,1], data[:,2], color=color)
        else
            plt.quiver(X, Y, data[:,1], data[:,2], color=color, scale=1.0/arrowscale)
        end
    end

    # Draw point numbers
    if pointlabels
        npoints = length(X)
        for i=1:npoints
            x = X[i] + 0.01*L
            y = Y[i] - 0.01*L
            z = Z[i] - 0.01*L
            if ndim==3
                ax.text(x, y, z, i, va="center", ha="center", backgroundcolor="none")
            else
                ax.text(x, y, i, va="top", ha="left", backgroundcolor="none")
            end
        end
    end

    # Draw cell numbers
    if celllabels && ndim==2
        for i=1:ncells
            coo = getcoords(cells[i])
            x = mean(coo[:,1])
            y = mean(coo[:,2])
            ax.text(x, y, i, va="top", ha="left", color="blue", backgroundcolor="none", size=8)
        end
    end

    if ndim==3 
        ax.view_init(elev=elev, azim=azim)
        ax.dist = dist
    end

    if filename==""
        plt.show()
    else
        plt.savefig(filename, bbox_inches="tight", pad_inches=0.00, format="pdf")
    end

    # Do not close if in IJulia
    if isdefined(Main, :IJulia) && Main.IJulia.inited
        return
    end
    if !leaveopen && filename=="" # only close if not saving to file
        plt.close("all")
    end

    return

end


#@doc """
#
#$(SIGNATURES)
#
#where `x` and `y` should both be positive.
#
 #Details
#
#Some details about `func`...
#""" mplot
#

