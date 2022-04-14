const ROUTE_COLOR="red"
const BEARING_DISTANCE = 15

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
    # drawing the non-edge-based graph, draw one path per vertex (which is a street segment)
    for v in LibSpatialIndex.intersects(state.graph.index, [west, south], [east, north])
        state.view == :normal && draw_single_segment(state, v)
        state.view == :turnbased && draw_exploded_segment(state, v)
    end

    # and the path, if there is one
    if !isnothing(state.path)
        sethue(ROUTE_COLOR)
        setline(2)
        for (idx, vertex) in enumerate(state.path[1:end - 1])
            state.view == :normal && draw_single_segment(state, vertex)
            state.view == :turnbased && draw_exploded_segment(state, vertex, only_dest=state.path[idx + 1])
        end
    end

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

# draw a single road segment (reprsented by a vertex)
function draw_single_segment(state, vertex)
    geom = get_prop(state.graph.graph, vertex, :geom)

    if length(geom) ≥ 2
        for (frll, toll) in zip(geom[1:end-1], geom[2:end])
            line(Luxor.Point(frll.lon, frll.lat), Luxor.Point(toll.lon, toll.lat), :stroke)
        end
    end
end

function offset_latlon(ll, heading, distance)
    pt = Luxor.Point(ll.lon, ll.lat)
    heading *= cosd(ll.lat)
    off = polar(distance, (heading - 90) * 2π / 360)
    res = pt + off
    LatLon(res.y, res.x)
end

offset_geometry(geom, bearing, distance) = map(enumerate(geom)) do (idx, pt)
    current_heading = StreetRouter.OSM.compute_heading(geom[max(idx - 1, 1)], geom[min(idx + 1, length(geom))])
    offset_heading = StreetRouter.OSM.circular_add(current_heading, bearing)
    offset_latlon(pt, offset_heading, distance)
end

function get_location_for_vertex(state, vertex)
    geom = get_prop(state.graph.graph, vertex, :geom)

    # offset 10 meters down the line
    base, idx = get_point_along_line(geom, 20)

    # offset 90 degrees to the right
    bearing = StreetRouter.OSM.compute_heading(geom[1], get_point_along_line(geom, 30)[1])
    offset_bearing = StreetRouter.OSM.circular_add(bearing, -90)

    # offset the point
    offset_latlon(base, offset_bearing, 5 / 111000), idx
end

function draw_exploded_segment(state, vertex; only_dest=nothing)
    geom = get_prop(state.graph.graph, vertex, :geom)
    loc, cutidx = get_location_for_vertex(state, vertex)

    # cut ends off geom
    startcut, startcutidx = get_point_along_line(geom, 30)
    endcut, endcutidx = get_point_along_line(geom, line_length(geom) - 30)
    base_geom = [startcut; geom[startcutidx + 1:endcutidx]; endcut]

    edge_geom = [loc; base_geom]
    # for (frll, toll) in zip(edge_geom[1:end - 1], edge_geom[2:end])
    #     line(Luxor.Point(frll.lon, frll.lat), Luxor.Point(toll.lon, toll.lat), :stroke)
    # end

    # sort the neighbors out by turn angle - left turns first
    next = outneighbors(state.graph.graph, vertex)
    sort!(next, by=x -> begin
            ang = get_prop(state.graph.graph, vertex, x, :turn_angle)
            ang > 170 ? -190 : ang
        end)

    # plot them
    for nbr in next
        base_geom = offset_geometry(base_geom, -90, 5/111000)
        if !isnothing(only_dest) && nbr != only_dest
            continue
        end

        next_loc, _ = get_location_for_vertex(state, nbr)
        edge_geom = [loc; base_geom]
        for (frll, toll) in zip(edge_geom[1:end - 1], edge_geom[2:end])
            line(Luxor.Point(frll.lon, frll.lat), Luxor.Point(toll.lon, toll.lat), :stroke)
        end
        frpt = Luxor.Point(base_geom[end].lon, base_geom[end].lat)
        topt = Luxor.Point(next_loc.lon, next_loc.lat)
        frpt ≈ topt || Luxor.line(frpt, topt)#; arrowheadlength=3/111000)
    end
end

line_length(geom) = sum(euclidean_distance.(geom[1:end-1], geom[2:end]))


function get_point_along_line(geom, distance)
    # loop over geom, accumulating distances
    dist = 0.0
    
    for i in 2:length(geom)
        seg_dist = euclidean_distance(geom[i-1], geom[i])
        if dist + seg_dist > distance
            seg_frac = (distance - dist) / seg_dist
            # generate the midpoint
            return (
                LatLon(
                    geom[i - 1].lat + (geom[i].lat - geom[i - 1].lat) * seg_frac,
                    geom[i - 1].lon + (geom[i].lon - geom[i - 1].lon) * seg_frac,
                ),
                i
            )
        end
    end

    # if we haven't returned by here, return endpoint
    geom[end], length(geom) - 1
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