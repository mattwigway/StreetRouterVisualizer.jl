struct GraphAndMetadata
    graph::AbstractGraph
    index::LibSpatialIndex.RTree
end

function read_graph(filename, window)
    G = deserialize(filename)
    # build a spatial index
    # note that geoms are attached to _vertices as this is an edge-based graph
    index = LibSpatialIndex.RTree(2)
    for v in 1:nv(G)
        geom = get_prop(G, v, :geom)
        lats = map(ll -> ll.lat, geom)
        lons = map(ll -> ll.lon, geom)
        LibSpatialIndex.insert!(index, v, [minimum(lons), minimum(lats)], [maximum(lons), maximum(lats)])
    end

    GraphAndMetadata(G, index)
end

function get_canvas_bbox(canvas, north, west, height_degrees)
    h = height(canvas)
    w = width(canvas)
    width_degrees = height_degrees / h * w / cosd(north)
    east = west + width_degrees
    south = north - height_degrees

    (north, east, south, west)
end

function draw_graph(graph, canvas, north, west, height_degrees)
    ctx = getgc(canvas)
    h = height(canvas)
    w = width(canvas)
    
    @info "n w h" north west height_degrees

    # figure out the south and west corners
    # the width is figured based on height in degrees per pixel divided by teh cosine of latitude
    # to correct for degrees of longitude getting smaller near the poles
    _, east, south, _ = get_canvas_bbox(canvas, north, west, height_degrees)

    # set the user coordinates to match spatial coordinates
    set_coordinates(ctx, BoundingBox(west, east, north, south))

    # just paint it white
    rectangle(ctx, west, south, east - west, north - south)
    set_source_rgb(ctx, 1, 1, 1)
    fill(ctx)

    set_source_rgb(ctx, 0, 0, 0)

    # find all edges that intersect
    for v in LibSpatialIndex.intersects(graph.index, [west, south], [east, north])
        geom = get_prop(graph.graph, v, :geom)

        if length(geom) ≥ 2
        # draw the geom
            move_to(ctx, geom[1].lon, geom[1].lat)
            for ll in geom[2:end]
                line_to(ctx, ll.lon, ll.lat)
            end
            stroke(ctx)
        end
    end
end
