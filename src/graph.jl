function read_graph(filename, window)
    G = deserialize(filename)

    StreetRouter.compute_freeflow_weights!(G)

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

function get_canvas_bbox(canvas, state::VisualizerState)
    h = height(canvas)
    w = width(canvas)
    width_degrees = state.height_degrees / h * w / cosd(state.north)
    east = state.west + width_degrees
    south = state.north - state.height_degrees

    (state.north, east, south, state.west)
end

function draw_graph(canvas, state::VisualizerState)
    ctx = getgc(canvas)
    h = height(canvas)
    w = width(canvas)
    
    # figure out the south and west corners
    # the width is figured based on height in degrees per pixel divided by teh cosine of latitude
    # to correct for degrees of longitude getting smaller near the poles
    _, east, south, _ = get_canvas_bbox(canvas, state)

    # set the user coordinates to match spatial coordinates
    set_coordinates(ctx, BoundingBox(state.west, east, state.north, south))

    # just paint it white
    rectangle(ctx, state.west, south, east - state.west, state.north - south)
    set_source_rgb(ctx, 1, 1, 1)
    fill(ctx)

    set_source_rgb(ctx, 0, 0, 0)

    # find all edges that intersect
    for v in LibSpatialIndex.intersects(state.graph.index, [state.west, south], [east, state.north])
        geom = get_prop(state.graph.graph, v, :geom)

        if length(geom) ≥ 2
        # draw the geom
            move_to(ctx, geom[1].lon, geom[1].lat)
            for ll in geom[2:end]
                line_to(ctx, ll.lon, ll.lat)
            end
            stroke(ctx)
        end
    end

    # draw the path
    if !isnothing(state.path)
        for (v1, v2) in zip(state.path[1:end - 1], state.path[2:end])
            draw_edge(ctx, state.graph, v1, v2, (1, 0, 0))
        end
    end

    # draw the origin and destination
    node_radius_degrees = 10 / h * state.height_degrees
    !isnothing(state.origin) && draw_node(ctx, state.graph, state.origin, (0, 0, 1), node_radius_degrees)
    !isnothing(state.destination) && draw_node(ctx, state.graph, state.destination, (1, 0, 0), node_radius_degrees)
end

function draw_node(ctx, graph, node, color, radius)
    set_source_rgb(ctx, color...)
    geom = get_prop(graph.graph, node, :geom)
    circle(ctx, geom[1].lon, geom[1].lat, radius)
    fill(ctx)
end

function draw_edge(ctx, graph, frnode, tonode, color)
    set_source_rgb(ctx, color...)
    geom = get_prop(graph.graph, frnode, :geom)

    @info "geom" geom

    if length(geom) ≥ 2
        # draw the geom
        move_to(ctx, geom[1].lon, geom[1].lat)
        for ll in geom[2:end]
            line_to(ctx, ll.lon, ll.lat)
        end
        stroke(ctx)
    end
end

function route!(state)
    paths = dijkstra_shortest_paths(state.graph.graph, state.origin)
    # reconstruct the path
    state.path = enumerate_paths(paths, state.destination)
    state.distance = paths.dists[state.destination]
end

function lonlat_for_click(canvas, e, state)
    _, east, south, _ = get_canvas_bbox(canvas, state)
    w = east - state.west
    h = state.north - south
    e_lon = e.x / width(canvas) * w + state.west
    e_lat = (1 - e.y / height(canvas)) * h + south
    @info "clicked lat, lon" e_lon e_lat
    e_lon, e_lat
end

node_for_lonlat(lon, lat, G) = LibSpatialIndex.knn(G.index, [lon, lat], 1)[1]