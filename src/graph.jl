const ROUTE_COLOR="red"

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

    drawing = Drawing(w, h)
    background("white")
    sethue("black")
    setline(1)


    # figure out the south and west corners
    # the width is figured based on height in degrees per pixel divided by teh cosine of latitude
    # to correct for degrees of longitude getting smaller near the poles
    north, east, south, west = get_canvas_bbox(canvas, state)

    # set scales appropriately
    # first, set relative scale of lon vs lat
    Luxor.scale(cosd(north), -1)

    # next, set overall scale
    Luxor.scale(h/ state.height_degrees)

    # pan to location
    Luxor.translate(-west, -north)
    
    # draw the graph
    # TODO switch to edge-based when zoomed in
    draw_normal(drawing, state, north, east, south, west)

    # draw the origin and destination
    node_radius_degrees = 10 / h * state.height_degrees
    !isnothing(state.origin) && draw_node(state.graph, state.origin, (0, 0, 1), node_radius_degrees)
    !isnothing(state.destination) && draw_node(state.graph, state.destination, (1, 0, 0), node_radius_degrees)

    # paint onto canvas
    # https://github.com/nodrygo/GtkLuxorNaiveDem
    Cairo.set_source_surface(ctx, drawing.surface)
    Cairo.paint(ctx)
end

function draw_node(graph, node, color, radius)
    sethue(color)
    geom = get_prop(graph.graph, node, :geom)
    Luxor.circle(geom[1].lon, geom[1].lat, radius, :fill)
end

"Draw a normal graph (i.e. no turn edges)"
function draw_normal(drawing, state, north, east, south, west)
    # drawing the non-edge-based graph, draw one path per vertex (which is a street segment)
    for v in LibSpatialIndex.intersects(state.graph.index, [west, south], [east, north])
        draw_single_edge(state, v)
    end

    # and the path, if there is one
    if !isnothing(state.path)
        sethue(ROUTE_COLOR)
        setline(2)
        for vertex in state.path[1:end - 1]
            draw_single_edge(state, vertex)
        end
    end
end

function draw_single_edge(state, vertex)
    geom = get_prop(state.graph.graph, vertex, :geom)

    if length(geom) ≥ 2
        for (frll, toll) in zip(geom[1:end-1], geom[2:end])
            line(Luxor.Point(frll.lon, frll.lat), Luxor.Point(toll.lon, toll.lat), :stroke)
        end
    end
end


function cruft()
    


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