struct GraphAndMetadata
    graph::AbstractGraph
    index::LibSpatialIndex.RTree
end

mutable struct VisualizerState
    west::Float64
    north::Float64
    height_degrees::Float64
    clickmode::Symbol
    view::Symbol
    origin::Union{Int64, Nothing}
    destination::Union{Int64, Nothing}
    path::Union{Vector{Int64}, Nothing}
    distance::Union{Float64, Nothing}
    graph::Union{GraphAndMetadata, Nothing}
end
