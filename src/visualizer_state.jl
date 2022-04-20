struct GraphAndMetadata
    graph::AbstractGraph
    index::LibSpatialIndex.RTree
    strong_components::Union{Nothing, Dict{Int64, Int64}}
end

mutable struct VisualizerState
    west::Float64
    north::Float64
    height_degrees::Float64
    clickmode::Symbol
    colormode::Symbol
    view::Symbol
    vertexlabels::Bool
    origin::Union{Int64, Nothing}
    destination::Union{Int64, Nothing}
    path::Union{Vector{Int64}, Nothing}
    distance::Union{Float64, Nothing}
    graph::Union{GraphAndMetadata, Nothing}
    graphpath::Union{Nothing, String}
    spt::Set{Int64}
end
